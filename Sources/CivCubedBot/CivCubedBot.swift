import Foundation
import AsyncKit
import AsyncHTTPClient
import DiscordBM
import FluentKit
import FluentSQLiteDriver

struct Config: Codable {
    var token: String
    var appID: ApplicationSnowflake
}

class DiscordInteraction {
    let client: any DiscordClient
    let event: Interaction

    init(client: any DiscordClient, interaction: Interaction) {
        self.client = client
        self.event = interaction
    }
    func reply(with: String, epheremal: Bool) async throws {
        _ = try await client.createInteractionResponse(
            id: event.id,
            token: event.token,
            payload: .channelMessageWithSource(.init(content: with, flags: epheremal ? [.ephemeral] : []))
        )
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

class Bot {
    let client: any DiscordClient
    let cache: DiscordCache
    let ev: any EventLoop
    let db: Database

    init(client: any DiscordClient, cache: DiscordCache, ev: any EventLoop, db: Database) {
        self.client = client
        self.cache = cache
        self.ev = ev
        self.db = db
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
    func slashCommand(cmd: String, user: DiscordUser, opts: [Interaction.ApplicationCommand.Option]?, intr: DiscordInteraction) async throws {
        switch cmd {
        case "allowlist":
            guard
                let opt = opts,
                let first = opt.first,
                let username = first.value?.asString
            else {
                try await intr.reply(with: "Oops, I had an error (Discord didn't send me an option...?)", epheremal: true)
                return
            }

            if let entry = try await Entry.find(UInt64(user.id.value), on: db) {
                entry.minecraftUsername = username
                try await entry.save(on: db)
                try await intr.reply(with: "Your username has been updated!", epheremal: true)
            } else {
                let entry = Entry()
                entry.id = UInt64(user.id.value)
                entry.minecraftUsername = username
                try await entry.save(on: db)
                try await intr.reply(with: "Your username has been recorded!", epheremal: true)
            }
        default:
            break
        }
    }
}

@main
struct CivCubedBotMain {
    static func actualMain(client httpClient: HTTPClient) async {
        let config = try! JSONDecoder().decode(Config.self,  from: try! String(contentsOfFile: "config.json").data(using: .utf8)!)

        let bot = BotGatewayManager(
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
        let mappoBot = Bot(client: bot.client, cache: cache, ev: httpClient.eventLoopGroup.next(), db: db)

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
        let httpClient = HTTPClient(eventLoopGroupProvider: .createNew)
        try! httpClient.eventLoopGroup.makeFutureWithTask {
            await actualMain(client: httpClient)
        }.wait()
        RunLoop.current.run()
    }
}
