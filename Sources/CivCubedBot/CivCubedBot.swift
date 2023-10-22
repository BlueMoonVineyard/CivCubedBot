import Foundation
import AsyncKit
import AsyncHTTPClient
import DiscordBM
import FluentKit
import FluentSQLiteDriver

struct Config: Codable {
    var token: String
    var appID: ApplicationSnowflake
    var apiToken: String
}

struct DiscordError: Error {
    let inner: DiscordHTTPErrorResponse
    let file: String
    let line: Int
    let column: Int
}

func throwDiscord<C: Codable>(fn: () async throws -> DiscordHTTP.DiscordClientResponse<C>, file: String = #file, line: Int = #line, column: Int = #column) async throws {
    let res = try await fn()
    if let err = res.asError() {
        throw DiscordError(inner: err, file: file, line: line, column: column)
    }
}

func throwDiscord(fn: () async throws -> DiscordHTTP.DiscordHTTPResponse, file: String = #file, line: Int = #line, column: Int = #column) async throws {
    let res = try await fn()
    if let err = res.asError() {
        throw DiscordError(inner: err, file: file, line: line, column: column)
    }
}

class DiscordInteraction {
    let client: any DiscordClient
    let event: Interaction
    var waited = false

    init(client: any DiscordClient, interaction: Interaction) {
        self.client = client
        self.event = interaction
    }
    func wait() async throws {
        try await throwDiscord {
            try await client.createInteractionResponse(
                id: event.id,
                token: event.token,
                payload: .deferredChannelMessageWithSource(isEphemeral: true)
            )
        }
        waited = true
    }
    func reply(with: String, epheremal: Bool) async throws {
        if !waited {
            try await throwDiscord {
                try await client.createInteractionResponse(
                    id: event.id,
                    token: event.token,
                    payload: .channelMessageWithSource(.init(content: with, flags: epheremal ? [.ephemeral] : []))
                )
            }
        } else {
            try await throwDiscord {
                try await client.updateOriginalInteractionResponse(
                    appId: client.appId,
                    token: event.token,
                    payload: .init(content: with)
                )
            }
        }
    }
}

final class Entry: Model {
    static let schema = "allowlist_entries"

    @ID(custom: .id)
    var id: UInt64?

    @Field(key: "minecraft_username")
    var minecraftUsername: String
}

struct CreateEntry: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("allowlist_entries")
            .field("id", .uint64, .required)
            .unique(on: "id", name: "unique_id")
            .field("minecraft_username", .string, .required)
            .create()
    }
    func revert(on database: Database) async throws {
        try await database.schema("allowlist_entries").delete()
    }
}

extension Result where Failure == Swift.Error {
    public init(catching body: () async throws -> Success) async {
        do {
            self = .success(try await body())
        } catch {
            self = .failure(error)
        }
    }
}

class Bot {
    let client: any DiscordClient
    let httpClient: HTTPClient
    let cache: DiscordCache
    let ev: any EventLoop
    let db: Database
    let apiToken: String

    init(client: any DiscordClient, httpClient: HTTPClient, cache: DiscordCache, ev: any EventLoop, db: Database, apiToken: String) {
        self.client = client
        self.httpClient = httpClient
        self.cache = cache
        self.ev = ev
        self.db = db
        self.apiToken = apiToken
    }
    func dispatch(ev: Gateway.Event) async throws {
        guard case .interactionCreate(let woot) = ev.data else {
            return
        }
        guard let ev = woot.data else {
            return
        }
        guard let user = woot.member?.user ?? woot.user else {
            return
        }
        let intr = DiscordInteraction(client: client, interaction: woot)

        switch ev {
        case .applicationCommand(let data):
            try await slashCommand(cmd: data.name, user: user, opts: data.options, intr: intr)
            break
        default:
            break
        }
    }
    func verifyUsername(username: String) async throws -> Bool {
        let resp = try await httpClient.get(url: "https://api.mojang.com/users/profiles/minecraft/\(username)").get()
        struct Resp: Codable {
            let id: String
        }
        guard
            var body = resp.body,
            let data = body.readData(length: body.readableBytes),
            let profile = try? JSONDecoder().decode(Resp.self, from: data)
        else {
            return false
        }
        _ = profile
        return true
    }
    enum LinkError: String, Error {
        case httpError
        case unknownError
        case accountAlreadyLinked
        case linkCodeDoesNotExist
        case linkCodeWasNotStartedFromMinecraft
        case linkCodeWasNotStartedFromDiscord

        var humanString: String {
            switch self {
            case .httpError:
                return "An error happened reading HTTP"
            case .unknownError:
                return "The server returned an unknown error"
            case .accountAlreadyLinked:
                return "Your account is already linked"
            case .linkCodeDoesNotExist:
                return "The given link code does not exist"
            case .linkCodeWasNotStartedFromMinecraft:
                return "The given link code needs to be used in Minecraft, not Discord"
            case .linkCodeWasNotStartedFromDiscord:
                return "The given link code needs to be used in Discord, not Minecraft"
            }
        }
    }
    func makeRequest(url: String, body: HTTPClientRequest.Body? = nil) -> HTTPClientRequest {
        var req = HTTPClientRequest(url: url)
        req.method = .POST
        req.headers.add(name: "Authorization", value: "Bearer \(apiToken)")
        req.body = body
        return req
    }
    func createLinkToken(discord: String) async throws -> String {
        let resp = try await httpClient.execute(makeRequest(url: "https://linkapi.civcubed.net/link/start/\(discord)"), timeout: .seconds(5))
        var body = try await resp.body.collect(upTo: 1024 * 1024)
        guard let data = body.readString(length: body.readableBytes) else {
            throw LinkError.httpError
        }

        if resp.status != .ok {
            throw LinkError.init(rawValue: data) ?? .unknownError
        }
        return data
    }
    func useLinkToken(discord: String, token: String) async throws {
        let resp = try await httpClient.execute(makeRequest(url: "https://linkapi.civcubed.net/link/complete/\(discord)", body: .bytes(token.data(using: .utf8)!)), timeout: .seconds(5))
        var body = try await resp.body.collect(upTo: 1024 * 1024)
        guard let data = body.readString(length: body.readableBytes) else {
            throw LinkError.httpError
        }

        if resp.status != .ok {
            throw LinkError.init(rawValue: data) ?? .unknownError
        }
    }
    func slashCommand(cmd: String, user: DiscordUser, opts: [Interaction.ApplicationCommand.Option]?, intr: DiscordInteraction) async throws {
        switch cmd {
        case "link-code":
            try await intr.wait()

            guard
                let opt = opts,
                let first = opt.first
            else {
                try await intr.reply(with: "Oops, I had an error (Discord didn't send me an option...?)", epheremal: true)
                return
            }
            switch first.name {
            case "create":
                let result = await Result { try await createLinkToken(discord: user.id.rawValue) }
                switch result {
                case .failure(let error as LinkError):
                    try await intr.reply(with: error.humanString, epheremal: true)
                case .failure(let error):
                    try await intr.reply(with: "I ran into an unknown error trying to create a link code: \(error)", epheremal: true)
                case .success(let code):
                    try await intr.reply(with: "Your link code is **\(code.uppercased())**. Use /link in Minecraft to link your Minecraft account with your Discord account.", epheremal: true)
                }
            case "use":
                guard
                    let subopt = first.options,
                    let first = subopt.first,
                    let code = first.value?.asString
                else {
                    try await intr.reply(with: "Oops, I had an error (Discord didn't send me a suboption...?)", epheremal: true)
                    return
                }
                let result = await Result { try await useLinkToken(discord: user.id.rawValue, token: code) }
                switch result {
                case .failure(let error as LinkError):
                    try await intr.reply(with: error.humanString, epheremal: true)
                case .failure(let error):
                    try await intr.reply(with: "I ran into an unknown error trying to use the link code: \(error)", epheremal: true)
                case .success(_):
                    try await intr.reply(with: "Your account has been successfully linked!", epheremal: true)
                }
            default:
                try await intr.reply(with: "I don't recognise that slash subcommand, sorry.", epheremal: true)
            }
        default:
            try await intr.reply(with: "I don't recognise that slash command, sorry.", epheremal: true)
        }
    }
}

@main
struct CivCubedBotMain {
    static func setCommandsMain(client httpClient: HTTPClient) async {
        let config = try! JSONDecoder().decode(Config.self,  from: try! String(contentsOfFile: "config.json").data(using: .utf8)!)

        print("Initializing bot...")
        let bot = await BotGatewayManager(
            eventLoopGroup: httpClient.eventLoopGroup,
            httpClient: httpClient,
            token: config.token,
            appId: config.appID,
            intents: [.guildMessages, .guildMembers, .messageContent]
        )

        print("Setting commands...")
        _ = try! await bot.client.bulkSetGuildApplicationCommands(guildId: "1052830294438330419", payload: [])
        let response = try! await bot.client.bulkSetApplicationCommands(payload: [
            .init(
                name: "link-code",
                description: "Link code commands",
                options: [
                    .init(
                        type: .subCommand,
                        name: "create",
                        description: "Create a linking code to be used from Minecraft"
                    ),
                    .init(
                        type: .subCommand,
                        name: "use",
                        description: "Link your account with the given code created in Minecraft",
                        options: [
                            .init(
                                type: .string,
                                name: "code",
                                description: "The link code obtained from running /link in Minecraft",
                                required: true
                            )
                        ]
                    )
                ]
            ),
        ])
        print(response)

        print("All done!")
    }
    static func actualMain(client httpClient: HTTPClient) async {
        let config = try! JSONDecoder().decode(Config.self,  from: try! String(contentsOfFile: "config.json").data(using: .utf8)!)

        let bot = await BotGatewayManager(
            eventLoopGroup: httpClient.eventLoopGroup,
            httpClient: httpClient,
            token: config.token,
            appId: config.appID,
            intents: [.guildMessages, .guildMembers, .messageContent]
        )
        let cache = await DiscordCache(
            gatewayManager: bot,
            intents: [.guildMembers],
            requestAllMembers: .enabled
        )

        let pool = NIOThreadPool(numberOfThreads: 2)
        pool.start()
        let dbs = Databases(threadPool: pool, on: httpClient.eventLoopGroup)
        dbs.use(.sqlite(.file("db.sqlite")), as: .sqlite)
        let db = dbs.database(logger: Logger.init(label: "databases"), on: httpClient.eventLoopGroup.next())!
        dbs.default(to: .sqlite)

        let migrations = Migrations()
        migrations.add(CreateEntry())
        let migrator = Migrator(databases: dbs, migrations: migrations, logger: Logger.init(label: "migrator"), on: httpClient.eventLoopGroup.next())
        do {
            try await migrator.setupIfNeeded().get()
            try await migrator.prepareBatch().get()
        } catch {
            Logger(label: "migrations").error("migrations failed!")
            Logger(label: "migrations").error("\(error)")
            return
        }
        let mappoBot = Bot(client: bot.client, httpClient: httpClient, cache: cache, ev: httpClient.eventLoopGroup.next(), db: db, apiToken: config.apiToken)

        await bot.connect()
        let stream = await bot.makeEventsStream()
        for await event in stream {
            do {
                try await mappoBot.dispatch(ev: event)
            } catch {
                print(error)
            }
        }
    }
    static func main() {
        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
        try! httpClient.eventLoopGroup.makeFutureWithTask {
            if CommandLine.arguments.last == "set-commands" {
                await setCommandsMain(client: httpClient)
            } else if CommandLine.arguments.last == "start-bot" {
                await actualMain(client: httpClient)
            } else {
                print("Unknown mode \(CommandLine.arguments.last ?? "")")
            }
        }.wait()
        RunLoop.current.run()
    }
}
