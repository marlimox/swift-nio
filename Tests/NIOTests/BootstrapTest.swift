//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

@testable import NIO
import NIOConcurrencyHelpers
import XCTest

class BootstrapTest: XCTestCase {
    var group: MultiThreadedEventLoopGroup!
    var groupBag: [MultiThreadedEventLoopGroup]? = nil // protected by `self.lock`
    let lock = Lock()

    override func setUp() {
        XCTAssertNil(self.group)
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.lock.withLock {
            XCTAssertNil(self.groupBag)
            self.groupBag = []
        }
    }

    override func tearDown() {
        XCTAssertNoThrow(try self.lock.withLock {
            guard let groupBag = self.groupBag else {
                XCTFail()
                return
            }
            XCTAssertNoThrow(try groupBag.forEach {
                XCTAssertNoThrow(try $0.syncShutdownGracefully())
            })
            self.groupBag = nil
            XCTAssertNotNil(self.group)
        })
        XCTAssertNoThrow(try self.group?.syncShutdownGracefully())
        self.group = nil
    }

    func freshEventLoop() -> EventLoop {
        let group: MultiThreadedEventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.lock.withLock {
            self.groupBag!.append(group)
        }
        return group.next()
    }

    func testBootstrapsCallInitializersOnCorrectEventLoop() throws {
        for numThreads in [1 /* everything on one event loop */,
                           2 /* some stuff has shared event loops */,
                           5 /* everything on a different event loop */] {
            let group = MultiThreadedEventLoopGroup(numberOfThreads: numThreads)
            defer {
                XCTAssertNoThrow(try group.syncShutdownGracefully())
            }

            let childChannelDone = group.next().makePromise(of: Void.self)
            let serverChannelDone = group.next().makePromise(of: Void.self)
            let serverChannel = try assertNoThrowWithValue(ServerBootstrap(group: group)
                .childChannelInitializer { channel in
                    XCTAssert(channel.eventLoop.inEventLoop)
                    childChannelDone.succeed(())
                    return channel.eventLoop.makeSucceededFuture(())
                }
                .serverChannelInitializer { channel in
                    XCTAssert(channel.eventLoop.inEventLoop)
                    serverChannelDone.succeed(())
                    return channel.eventLoop.makeSucceededFuture(())
                }
                .bind(host: "localhost", port: 0)
                .wait())
            defer {
                XCTAssertNoThrow(try serverChannel.close().wait())
            }

            let client = try assertNoThrowWithValue(ClientBootstrap(group: group)
                .channelInitializer { channel in
                    XCTAssert(channel.eventLoop.inEventLoop)
                    return channel.eventLoop.makeSucceededFuture(())
                }
                .connect(to: serverChannel.localAddress!)
                .wait(), message: "resolver debug info: \(try! resolverDebugInformation(eventLoop: group.next(),host: "localhost", previouslyReceivedResult: serverChannel.localAddress!))")
            defer {
                XCTAssertNoThrow(try client.syncCloseAcceptingAlreadyClosed())
            }
            XCTAssertNoThrow(try childChannelDone.futureResult.wait())
            XCTAssertNoThrow(try serverChannelDone.futureResult.wait())
        }
    }

    func testTCPBootstrapsTolerateFuturesFromDifferentEventLoopsReturnedInInitializers() throws {
        let childChannelDone = self.freshEventLoop().makePromise(of: Void.self)
        let serverChannelDone = self.freshEventLoop().makePromise(of: Void.self)
        let serverChannel = try assertNoThrowWithValue(ServerBootstrap(group: self.freshEventLoop())
            .childChannelInitializer { channel in
                XCTAssert(channel.eventLoop.inEventLoop)
                defer {
                    childChannelDone.succeed(())
                }
                return self.freshEventLoop().makeSucceededFuture(())
            }
            .serverChannelInitializer { channel in
                XCTAssert(channel.eventLoop.inEventLoop)
                defer {
                    serverChannelDone.succeed(())
                }
                return self.freshEventLoop().makeSucceededFuture(())
            }
            .bind(host: "127.0.0.1", port: 0)
            .wait())
        defer {
            XCTAssertNoThrow(try serverChannel.close().wait())
        }

        let client = try assertNoThrowWithValue(ClientBootstrap(group: self.freshEventLoop())
            .channelInitializer { channel in
                XCTAssert(channel.eventLoop.inEventLoop)
                return self.freshEventLoop().makeSucceededFuture(())
            }
            .connect(to: serverChannel.localAddress!)
            .wait())
        defer {
            XCTAssertNoThrow(try client.syncCloseAcceptingAlreadyClosed())
        }
        XCTAssertNoThrow(try childChannelDone.futureResult.wait())
        XCTAssertNoThrow(try serverChannelDone.futureResult.wait())
    }

    func testUDPBootstrapToleratesFuturesFromDifferentEventLoopsReturnedInInitializers() throws {
        XCTAssertNoThrow(try DatagramBootstrap(group: self.freshEventLoop())
            .channelInitializer { channel in
                XCTAssert(channel.eventLoop.inEventLoop)
                return self.freshEventLoop().makeSucceededFuture(())
            }
            .bind(host: "127.0.0.1", port: 0)
            .wait()
            .close()
            .wait())
    }

    func testPreConnectedClientSocketToleratesFuturesFromDifferentEventLoopsReturnedInInitializers() throws {
        var socketFDs: [CInt] = [-1, -1]
        XCTAssertNoThrow(try Posix.socketpair(domain: PF_LOCAL,
                                              type: Posix.SOCK_STREAM,
                                              protocol: 0,
                                              socketVector: &socketFDs))
        defer {
            // 0 is closed together with the Channel below.
            XCTAssertNoThrow(try Posix.close(descriptor: socketFDs[1]))
        }

        XCTAssertNoThrow(try ClientBootstrap(group: self.freshEventLoop())
            .channelInitializer { channel in
                XCTAssert(channel.eventLoop.inEventLoop)
                return self.freshEventLoop().makeSucceededFuture(())
            }
            .withConnectedSocket(descriptor: socketFDs[0])
            .wait()
            .close()
            .wait())
    }

    func testPreConnectedServerSocketToleratesFuturesFromDifferentEventLoopsReturnedInInitializers() throws {
        let socket = try Posix.socket(domain: AF_INET, type: Posix.SOCK_STREAM, protocol: 0)

        let serverAddress = try assertNoThrowWithValue(SocketAddress.makeAddressResolvingHost("127.0.0.1", port: 0))
        try serverAddress.withSockAddr { serverAddressPtr, size in
            try Posix.bind(descriptor: socket, ptr: serverAddressPtr,
                           bytes: size)
        }

        let childChannelDone = self.freshEventLoop().next().makePromise(of: Void.self)
        let serverChannelDone = self.freshEventLoop().next().makePromise(of: Void.self)

        let serverChannel = try assertNoThrowWithValue(try ServerBootstrap(group: self.freshEventLoop())
            .childChannelInitializer { channel in
                XCTAssert(channel.eventLoop.inEventLoop)
                defer {
                    childChannelDone.succeed(())
                }
                return self.freshEventLoop().makeSucceededFuture(())
            }
            .serverChannelInitializer { channel in
                XCTAssert(channel.eventLoop.inEventLoop)
                defer {
                    serverChannelDone.succeed(())
                }
                return self.freshEventLoop().makeSucceededFuture(())
            }
            .withBoundSocket(descriptor: socket)
            .wait())
        let client = try assertNoThrowWithValue(ClientBootstrap(group: self.freshEventLoop())
            .channelInitializer { channel in
                XCTAssert(channel.eventLoop.inEventLoop)
                return self.freshEventLoop().makeSucceededFuture(())
            }
            .connect(to: serverChannel.localAddress!)
            .wait())
        defer {
            XCTAssertNoThrow(try client.syncCloseAcceptingAlreadyClosed())
        }
        XCTAssertNoThrow(try childChannelDone.futureResult.wait())
        XCTAssertNoThrow(try serverChannelDone.futureResult.wait())
    }

    func testTCPClientBootstrapAllowsConformanceCorrectly() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        func restrictBootstrapType(clientBootstrap: NIOTCPClientBootstrap) throws {
            let serverAcceptedChannelPromise = group.next().makePromise(of: Channel.self)
            let serverChannel = try assertNoThrowWithValue(ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
                .childChannelInitializer { channel in
                    serverAcceptedChannelPromise.succeed(channel)
                    return channel.eventLoop.makeSucceededFuture(())
            }.bind(host: "127.0.0.1", port: 0).wait())

            let clientChannel = try assertNoThrowWithValue(clientBootstrap
                .channelInitializer({ (channel: Channel) in channel.eventLoop.makeSucceededFuture(()) })
                .connect(host: "127.0.0.1", port: serverChannel.localAddress!.port!).wait())

            var buffer = clientChannel.allocator.buffer(capacity: 1)
            buffer.writeString("a")
            try clientChannel.writeAndFlush(NIOAny(buffer)).wait()

            let serverAcceptedChannel = try serverAcceptedChannelPromise.futureResult.wait()

            // Start shutting stuff down.
            XCTAssertNoThrow(try clientChannel.close().wait())

            // Wait for the close promises. These fire last.
            XCTAssertNoThrow(try EventLoopFuture.andAllSucceed([clientChannel.closeFuture,
                                                                serverAcceptedChannel.closeFuture],
                                                                on: group.next()).wait())
        }

        if let bootstrap = group.makeTCPClientBootstrap() {
            try restrictBootstrapType(clientBootstrap: bootstrap)
        } else {
            XCTFail("Did not generate a valid Bootstrap")
        }
    }
    
    func testServerBootstrapBindTimeout() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        // Set a bindTimeout and call bind. Setting a bind timeout is currently unsupported
        // by ServerBootstrap. We therefore expect the bind timeout to be ignored and bind to
        // succeed, even with a minimal bind timeout.
        let bootstrap = ServerBootstrap(group: group)
            .bindTimeout(.nanoseconds(0))

        let channel = try assertNoThrowWithValue(bootstrap.bind(host: "127.0.0.1", port: 0).wait())
        XCTAssertNoThrow(try channel.close().wait())
    }

    func testServerBootstrapSetsChannelOptionsBeforeChannelInitializer() {
        var channel: Channel? = nil
        XCTAssertNoThrow(channel = try ServerBootstrap(group: self.group)
            .serverChannelOption(ChannelOptions.autoRead, value: false)
            .serverChannelInitializer { channel in
                channel.getOption(ChannelOptions.autoRead).whenComplete { result in
                    func workaround() {
                        XCTAssertNoThrow(XCTAssertFalse(try result.get()))
                    }
                    workaround()
                }
                return channel.pipeline.addHandler(MakeSureAutoReadIsOffInChannelInitializer())
        }
        .bind(to: .init(ipAddress: "127.0.0.1", port: 0))
        .wait())
        XCTAssertNotNil(channel)
        XCTAssertNoThrow(try channel?.close().wait())
    }

    func testClientBootstrapSetsChannelOptionsBeforeChannelInitializer() {
        XCTAssertNoThrow(try withTCPServerChannel(group: self.group) { server in
            var channel: Channel? = nil
            XCTAssertNoThrow(channel = try ClientBootstrap(group: self.group)
                .channelOption(ChannelOptions.autoRead, value: false)
                .channelInitializer { channel in
                    channel.getOption(ChannelOptions.autoRead).whenComplete { result in
                        func workaround() {
                            XCTAssertNoThrow(XCTAssertFalse(try result.get()))
                        }
                        workaround()
                    }
                    return channel.pipeline.addHandler(MakeSureAutoReadIsOffInChannelInitializer())
            }
            .connect(to: server.localAddress!)
            .wait())
            XCTAssertNotNil(channel)
            XCTAssertNoThrow(try channel?.close().wait())
        })
    }

    func testPreConnectedSocketSetsChannelOptionsBeforeChannelInitializer() {
        XCTAssertNoThrow(try withTCPServerChannel(group: self.group) { server in
            var maybeSocket: Socket? = nil
            XCTAssertNoThrow(maybeSocket = try Socket(protocolFamily: AF_INET, type: Posix.SOCK_STREAM))
            XCTAssertNoThrow(XCTAssertEqual(true, try maybeSocket?.connect(to: server.localAddress!)))
            var maybeFD: CInt? = nil
            XCTAssertNoThrow(maybeFD = try maybeSocket?.takeDescriptorOwnership())
            guard let fd = maybeFD else {
                XCTFail("could not get a socket fd")
                return
            }

            var channel: Channel? = nil
            XCTAssertNoThrow(channel = try ClientBootstrap(group: self.group)
                .channelOption(ChannelOptions.autoRead, value: false)
                .channelInitializer { channel in
                    channel.getOption(ChannelOptions.autoRead).whenComplete { result in
                        func workaround() {
                            XCTAssertNoThrow(XCTAssertFalse(try result.get()))
                        }
                        workaround()
                    }
                    return channel.pipeline.addHandler(MakeSureAutoReadIsOffInChannelInitializer())
            }
            .withConnectedSocket(descriptor: fd)
            .wait())
            XCTAssertNotNil(channel)
            XCTAssertNoThrow(try channel?.close().wait())
        })
    }

    func testDatagramBootstrapSetsChannelOptionsBeforeChannelInitializer() {
        var channel: Channel? = nil
        XCTAssertNoThrow(channel = try DatagramBootstrap(group: self.group)
            .channelOption(ChannelOptions.autoRead, value: false)
            .channelInitializer { channel in
                channel.getOption(ChannelOptions.autoRead).whenComplete { result in
                    func workaround() {
                        XCTAssertNoThrow(XCTAssertFalse(try result.get()))
                    }
                    workaround()
                }
                return channel.pipeline.addHandler(MakeSureAutoReadIsOffInChannelInitializer())
        }
        .bind(to: .init(ipAddress: "127.0.0.1", port: 0))
        .wait())
        XCTAssertNotNil(channel)
        XCTAssertNoThrow(try channel?.close().wait())
    }

    func testPipeBootstrapSetsChannelOptionsBeforeChannelInitializer() {
        XCTAssertNoThrow(try withPipe { inPipe, outPipe in
            var maybeInFD: CInt? = nil
            var maybeOutFD: CInt? = nil
            XCTAssertNoThrow(maybeInFD = try inPipe.takeDescriptorOwnership())
            XCTAssertNoThrow(maybeOutFD = try outPipe.takeDescriptorOwnership())
            guard let inFD = maybeInFD, let outFD = maybeOutFD else {
                XCTFail("couldn't get pipe fds")
                return [inPipe, outPipe]
            }
            var channel: Channel? = nil
            XCTAssertNoThrow(channel = try NIOPipeBootstrap(group: self.group)
                .channelOption(ChannelOptions.autoRead, value: false)
                .channelInitializer { channel in
                    channel.getOption(ChannelOptions.autoRead).whenComplete { result in
                        func workaround() {
                            XCTAssertNoThrow(XCTAssertFalse(try result.get()))
                        }
                        workaround()
                    }
                    return channel.pipeline.addHandler(MakeSureAutoReadIsOffInChannelInitializer())
            }
            .withPipes(inputDescriptor: inFD, outputDescriptor: outFD)
            .wait())
            XCTAssertNotNil(channel)
            XCTAssertNoThrow(try channel?.close().wait())
            return []
        })
    }

    func testServerBootstrapAddsAcceptHandlerAfterServerChannelInitialiser() {
        // It's unclear if this is the right solution, see https://github.com/apple/swift-nio/issues/1392
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer {
            XCTAssertNoThrow(try group.syncShutdownGracefully())
        }

        struct FoundHandlerThatWasNotSupposedToBeThereError: Error {}

        var maybeServer: Channel? = nil
        XCTAssertNoThrow(maybeServer = try ServerBootstrap(group: group)
            .serverChannelInitializer { channel in
                // Here, we test that we can't find the AcceptHandler
                return channel.pipeline.context(name: "AcceptHandler").flatMap { context -> EventLoopFuture<Void> in
                    XCTFail("unexpectedly found \(context)")
                    return channel.eventLoop.makeFailedFuture(FoundHandlerThatWasNotSupposedToBeThereError())
                }.flatMapError { error -> EventLoopFuture<Void> in
                    XCTAssertEqual(.notFound, error as? ChannelPipelineError)
                    if case .some(.notFound) = error as? ChannelPipelineError {
                        return channel.eventLoop.makeSucceededFuture(())
                    }
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .wait())

        guard let server = maybeServer else {
            XCTFail("couldn't bootstrap server")
            return
        }

        // But now, it should be there.
        XCTAssertNoThrow(_ = try server.pipeline.context(name: "AcceptHandler").wait())
        XCTAssertNoThrow(try server.close().wait())
    }
}

private final class MakeSureAutoReadIsOffInChannelInitializer:  ChannelInboundHandler {
    typealias InboundIn = Channel

    func channelActive(context: ChannelHandlerContext) {
        context.channel.getOption(ChannelOptions.autoRead).whenComplete { result in
            func workaround() {
                XCTAssertNoThrow(XCTAssertFalse(try result.get()))
            }
            workaround()
        }
    }
}
