//
//  TorServer.swift
//  SnowHaze
//
//
//  Copyright © 2019 Illotros GmbH. All rights reserved.
//

import Foundation
import Tor

private func clean<C: Collection>(_ c: C?) -> C? {
	if let c = c, !c.isEmpty {
		return c
	}
	return nil
}

class TorServer {
	private static let socketDir: URL = {
#if !(arch(i386) || arch(x86_64))
		return FileManager.default.temporaryDirectory.appendingPathComponent("sock")
#else
		return URL(fileURLWithPath: "/Users/Shared/SimulatorSockets/SnowHaze")
#endif
	}()
	private static let socket = socketDir.appendingPathComponent("tor.sock")

	enum Error: Swift.Error {
		case filesystemError
		case noSubscription
		case controlConnectionFailure
		case controlConnectionTimeout
		case controlAuthenticationFailure(Swift.Error)
	}

	private init() { }
	static let shared = TorServer()

	var running = false

	private var controller: TorController?

	private var connectionProxyDictionaryInitialized = false
	private(set) var connectionProxyDictionary: [AnyHashable : Any]?

	private var startCallbacks: [(Error?) -> Void] = []
	private var proxyConfigCallbacks: [([AnyHashable : Any]?) -> Void] = []

	let bootstrapProgress = Progress(totalUnitCount: 100)

	private func notify(error: Error?) {
		let callbacks = startCallbacks
		startCallbacks = []
		if let _ = error {
			self.controller?.disconnect()
			self.controller = nil
			notify(proxyConfig: nil)
		}
		syncToMainThread {
			for callback in callbacks {
				callback(error)
			}
		}
	}

	private func notify(proxyConfig: [AnyHashable : Any]?) {
		let callbacks = proxyConfigCallbacks
		proxyConfigCallbacks = []
		for callback in callbacks {
			callback(proxyConfig)
		}
	}

	func start(callback: @escaping (Error?) -> Void) {
		guard !running else {
			callback(nil)
			return
		}
		guard SubscriptionManager.status.possible else {
			callback(.noSubscription)
			return
		}
		startCallbacks.append(callback)
		guard startCallbacks.count == 1 else {
			return
		}

		let dataDir = FileManager.default.temporaryDirectory
		let cookieURL = dataDir.appendingPathComponent("control_auth_cookie")
		try? FileManager.default.removeItem(at: cookieURL)
		try? FileManager.default.removeItem(at: TorServer.socket)
		try? FileManager.default.createDirectory(at: TorServer.socketDir, withIntermediateDirectories: true, attributes: [FileAttributeKey.posixPermissions: 0o700])
		let fd = dataDir.withUnsafeFileSystemRepresentation({ open_constcharp_int($0, O_EVTONLY) })
		guard fd >= 0 else {
			return notify(error: .filesystemError)
		}
		let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .all)
		source.setEventHandler {
			guard let cookie = try? Data(contentsOf: cookieURL) else {
				return
			}
			source.cancel()
			print("setting up controller")
			self.controller = TorController(socketURL: TorServer.socket)
			guard self.controller!.isConnected else {
				return self.notify(error: .controlConnectionFailure)
			}
			self.controller?.authenticate(with: cookie) { success, error in
				DispatchQueue.main.async {
					self.running = success
					self.notify(error: success ? nil : .controlAuthenticationFailure(error!))
					print("authenticated? \(success)")
					if success {
						self.controller!.getSessionConfiguration { config in
							DispatchQueue.main.async {
								print("got config? \(config as Any? ?? "no") \(Thread.current.name ?? "noname")")
								self.connectionProxyDictionaryInitialized = true
								self.connectionProxyDictionary = config?.connectionProxyDictionary
								self.notify(proxyConfig: self.connectionProxyDictionary)

								self.controller!.addObserver { success in
									print("connection establisched? \(success)")
									DispatchQueue.main.async {
										self.bootstrapProgress.completedUnitCount = success ? 100 : 0
									}
								}
								self.controller!.addObserver { type, severity, action, arguments -> Bool in
									print("tor event \(type) \(severity) \(action): \(arguments as Any)")
									if type == "STATUS_CLIENT" && severity == "NOTICE" && action == "BOOTSTRAP" {
										if let progress = arguments?["PROGRESS"], let progressNumber = Int64(progress) {
											DispatchQueue.main.async {
												self.bootstrapProgress.completedUnitCount = progressNumber
											}
										}
										return true
									}
									return false
								}
							}
						}
					}
				}
			}
		}
		source.resume()

		if TorThread.active == nil {
			let config = TorConfiguration()
			var options = [String: String]()
			if let path =  Bundle.main.path(forResource: "geoip", ofType: nil) {
				options["GeoIPFile"] = path
			}
			if let path =  Bundle.main.path(forResource: "geoip6", ofType: nil) {
				options["GeoIPv6File"] = path
			}
			config.options = options
			config.controlSocket = TorServer.socket
			config.cookieAuthentication = true
			config.dataDirectory = dataDir
			config.arguments = ["--ignore-missing-torrc"]

			TorThread(configuration: config).start()
		}
	}

	func getURLSessionProxyConfig(callback: @escaping ([AnyHashable : Any]?) -> Void) {
		guard !connectionProxyDictionaryInitialized else {
			return callback(connectionProxyDictionary)
		}
		proxyConfigCallbacks.append(callback)
	}

	struct Node {
		private let raw: TorNode
		init(node: TorNode) {
			raw = node
		}

		var country: String? {
			return clean(raw.countryCode)
		}

		var fingerprint: String? {
			return clean(raw.fingerprint)
		}

		var IPv4: String? {
			return clean(raw.ipv4Address)
		}

		var IPv6: String? {
			return clean(raw.ipv6Address)
		}

		var nickname: String? {
			return clean(raw.nickName)
		}
	}

	struct Circuit {
		private let raw: TorCircuit
		init(circuit: TorCircuit) {
			raw = circuit
		}

		var user: String? {
			return clean(raw.socksUsername)
		}

		var password: String? {
			return clean(raw.socksPassword)
		}

		var nodes: [Node]? {
			return clean(raw.nodes?.map { Node(node: $0) })
		}

		var id: String? {
			return clean(raw.circuitId)
		}

		var status: String? {
			return clean(raw.status)
		}

		var buildFlags: [String]? {
			return clean(raw.buildFlags?.filter { !$0.isEmpty })
		}

		var purpose: String? {
			return clean(raw.purpose)
		}

		var hiddenServiceState: String? {
			return clean(raw.hsState)
		}

		var rendezvousQuery: String? {
			return clean(raw.rendQuery)
		}

		var created: Date? {
			return raw.timeCreated
		}

		var reason: String? {
			return clean(raw.reason)
		}

		var remoteReason: String? {
			return clean(raw.remoteReason)
		}
	}
	func getCircuits(callback: @escaping ([Circuit]?) -> Void) {
		guard let controller = controller else {
			return callback(nil)
		}
		controller.getCircuits { circuits in
			syncToMainThread {
				callback(circuits.map { Circuit(circuit: $0) } )
			}
		}
	}
}
