import NIO

extension Request {
    public var fileio: FileIO {
        return .init(
            io: self.application.fileio,
            allocator: self.application.allocator,
            request: self
        )
    }
}

// MARK: FileIO

/// `FileIO` is a convenience wrapper around SwiftNIO's `NonBlockingFileIO`.
///
/// It can read files, both in their entirety and chunked.
///
///     let fileio = try c.make(FileIO.self)
///
///     fileio.readFile(at: "/path/to/file.txt") { chunk in
///         print(chunk) // part of file
///     }
///
///     fileio.collectFile(at: "/path/to/file.txt").map { file in
///         print(file) // entire file
///     }
///
/// It can also create streaming HTTP responses.
///
///     let fileio = try c.make(FileIO.self)
///     router.get("file-stream") { req -> Response in
///         return fileio.streamFile(at: "/path/to/file.txt", for: req)
///     }
///
/// Streaming file responses respect `E-Tag` headers present in the request.
public struct FileIO {
    /// Wrapped non-blocking file io from SwiftNIO
    private let io: NonBlockingFileIO

    /// ByteBufferAllocator to use for generating buffers.
    private let allocator: ByteBufferAllocator
    
    /// HTTP request context.
    private let request: Request

    /// Creates a new `FileIO`.
    ///
    /// See `Request.fileio()` to create one.
    internal init(io: NonBlockingFileIO, allocator: ByteBufferAllocator, request: Request) {
        self.io = io
        self.allocator = allocator
        self.request = request
    }

    /// Reads the contents of a file at the supplied path.
    ///
    ///     let data = try req.fileio().read(file: "/path/to/file.txt").wait()
    ///     print(data) // file data
    ///
    /// - parameters:
    ///     - path: Path to file on the disk.
    /// - returns: `Future` containing the file data.
    public func collectFile(at path: String) -> EventLoopFuture<ByteBuffer> {
        var data = self.allocator.buffer(capacity: 0)
        return self.readFile(at: path) { new in
            var new = new
            data.writeBuffer(&new)
            return self.request.eventLoop.makeSucceededFuture(())
        }.map { data }
    }

    /// Reads the contents of a file at the supplied path in chunks.
    ///
    ///     try req.fileio().readChunked(file: "/path/to/file.txt") { chunk in
    ///         print("chunk: \(data)")
    ///     }.wait()
    ///
    /// - parameters:
    ///     - path: Path to file on the disk.
    ///     - chunkSize: Maximum size for the file data chunks.
    ///     - onRead: Closure to be called sequentially for each file data chunk.
    /// - returns: `Future` that will complete when the file read is finished.
    public func readFile(
        at path: String,
        chunkSize: Int = NonBlockingFileIO.defaultChunkSize,
        onRead: @escaping (ByteBuffer) -> EventLoopFuture<Void>
    ) -> EventLoopFuture<Void> {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            let fileSize = attributes[.size] as? NSNumber
        else {
            return self.request.eventLoop.makeFailedFuture(Abort(.internalServerError))
        }
        return self.read(path: path, fileSize: fileSize.intValue, chunkSize: chunkSize, onRead: onRead)
    }

    /// Generates a chunked `HTTPResponse` for the specified file. This method respects values in
    /// the `"ETag"` header and is capable of responding `304 Not Modified` if the file in question
    /// has not been modified since last served. This method will also set the `"Content-Type"` header
    /// automatically if an appropriate `MediaType` can be found for the file's suffix.
    ///
    ///     router.get("file-stream") { req -> HTTPResponse in
    ///         return try req.fileio().chunkedResponse(file: "/path/to/file.txt")
    ///     }
    ///
    /// - parameters:
    ///     - path: Path to file on the disk.
    ///     - req: `HTTPRequest` to parse `"If-None-Match"` header from.
    ///     - chunkSize: Maximum size for the file data chunks.
    /// - returns: A `200 OK` response containing the file stream and appropriate headers.
    public func streamFile(at path: String, chunkSize: Int = NonBlockingFileIO.defaultChunkSize) -> Response {
        // Get file attributes for this file.
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            let modifiedAt = attributes[.modificationDate] as? Date,
            let fileSize = (attributes[.size] as? NSNumber)?.intValue
        else {
            return Response(status: .internalServerError)
        }

        // Create empty headers array.
        var headers: HTTPHeaders = [:]

        // Generate ETag value, "HEX value of last modified date" + "-" + "file size"
        let fileETag = "\(modifiedAt.timeIntervalSince1970)-\(fileSize)"
        headers.replaceOrAdd(name: .eTag, value: fileETag)

        // Check if file has been cached already and return NotModified response if the etags match
        if fileETag == request.headers.first(name: .ifNoneMatch) {
            return Response(status: .notModified)
        }

        // Create the HTTP response.
        let response = Response(status: .ok, headers: headers)

        // Set Content-Type header based on the media type
        // Only set Content-Type if file not modified and returned above.
        if
            let fileExtension = path.components(separatedBy: ".").last,
            let type = HTTPMediaType.fileExtension(fileExtension)
        {
            response.headers.contentType = type
        }

        response.body = .init(stream: { stream in
            self.read(path: path, fileSize: fileSize, chunkSize: chunkSize) { chunk in
                return stream.write(.buffer(chunk))
            }.whenComplete { result in
                switch result {
                case .failure(let error):
                    stream.write(.error(error), promise: nil)
                case .success:
                    stream.write(.end, promise: nil)
                }
            }
        }, count: fileSize)
        
        return response
    }

    /// Private read method. `onRead` closure uses ByteBuffer and expects future return.
    /// There may be use in publicizing this in the future for reads that must be async.
    private func read(
        path: String,
        fileSize: Int,
        chunkSize: Int,
        onRead: @escaping (ByteBuffer) -> EventLoopFuture<Void>
    ) -> EventLoopFuture<Void> {
        do {
            let fd = try NIOFileHandle(path: path)
            let done = self.io.readChunked(
                fileHandle: fd,
                byteCount: fileSize,
                chunkSize: chunkSize,
                allocator: allocator,
                eventLoop: self.request.eventLoop
            ) { chunk in
                return onRead(chunk)
            }
            done.whenComplete { _ in
                try? fd.close()
            }
            return done
        } catch {
            return self.request.eventLoop.makeFailedFuture(error)
        }
    }
}
