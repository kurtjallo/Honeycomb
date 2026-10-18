import GRDB

/// The built-in note templates. Each lists the sections the notes must have, in order.
/// Seeded into the `template` table at launch, so edits here reach existing installs.
public enum BuiltInTemplates {
    public static let general = TemplateRecord(
        id: "general", name: "General",
        instructions: "Write clear notes for someone who missed the meeting. Lead with what was decided and what happens next.",
        sections: ["Summary", "Key points", "Decisions", "Action items"], builtIn: true)

    public static let sync = TemplateRecord(
        id: "sync", name: "1:1 or team sync",
        instructions: "Focus on progress since last time, blockers, and who is doing what next. Keep each update short.",
        sections: ["Updates", "Blockers", "Decisions", "Action items"], builtIn: true)

    public static let customer = TemplateRecord(
        id: "customer", name: "Customer call",
        instructions: "Capture the customer's situation in their own terms: needs, pain points, objections, budget, timeline, and who decides. Quote short phrases that show urgency or doubt.",
        sections: ["Summary", "Their needs", "Concerns and objections", "Timeline and decision process", "Next steps"],
        builtIn: true)

    public static let interview = TemplateRecord(
        id: "interview", name: "Interview",
        instructions: "Record evidence, not impressions: what the candidate said and did, with examples. Note anything to follow up on. Don't give a hiring recommendation unless I wrote one.",
        sections: ["Background", "Strengths", "Concerns", "Notable answers", "Follow-ups"], builtIn: true)

    public static let investor = TemplateRecord(
        id: "investor", name: "Investor or partner call",
        instructions: "Capture their questions, their concerns, any numbers or terms mentioned, and what each side promised to send or do.",
        sections: ["Summary", "Their questions", "Concerns", "Numbers and terms", "Next steps"], builtIn: true)

    public static let all = [general, sync, customer, interview, investor]
}

public enum BuiltInRecipes {
    public static let all = [
        Recipe(id: "follow-up-email", name: "Write follow-up email",
               prompt: "Write a short follow-up email to the other people in this meeting. Thank them, restate what was agreed, and list next steps with owners and dates where they were said. Plain text, no subject line unless asked.",
               scope: .one, builtIn: true),
        Recipe(id: "action-items", name: "List action items",
               prompt: "List every action item from this meeting as a checklist. Put the owner first if someone was named, and the due date at the end if one was said. Don't invent owners or dates.",
               scope: .one, builtIn: true),
        Recipe(id: "what-did-i-miss", name: "What did I miss?",
               prompt: "Summarize the last few minutes of the conversation in 2 to 4 bullets, so I can catch up right now.",
               scope: .one, builtIn: true),
        Recipe(id: "slack-summary", name: "Summarize for Slack",
               prompt: "Write a short Slack message summarizing this meeting for teammates who weren't there: one line of context, 3 to 5 bullets, and next steps. Use Slack formatting.",
               scope: .one, builtIn: true),
    ]
}

extension AppDatabase {
    /// Refreshes built-in templates, recipes, call apps, and the built-in provider. User-made rows are never touched.
    public func seedBuiltIns() throws {
        try writer.write { db in
            for template in BuiltInTemplates.all { try template.save(db) }
            for recipe in BuiltInRecipes.all { try recipe.save(db) }
            for app in CallAppCatalog.builtIn where try CallApp.fetchOne(db, key: app.bundleId) == nil {
                try app.insert(db)
            }
            if try ProviderRecord.fetchOne(db, key: ProviderRecord.builtIn.id) == nil {
                try ProviderRecord.builtIn.insert(db)
            }
        }
    }

    public func templates() throws -> [TemplateRecord] {
        try reader.read { try TemplateRecord.order(Column("built_in").desc, Column("name")).fetchAll($0) }
    }

    public func template(_ id: String?) throws -> TemplateRecord {
        let found = try id.flatMap { id in try reader.read { try TemplateRecord.fetchOne($0, key: id) } }
        return found ?? BuiltInTemplates.general
    }

    public func saveTemplate(_ template: TemplateRecord) throws {
        try writer.write { try template.save($0) }
    }

    public func deleteTemplate(_ id: String) throws {
        _ = try writer.write { try TemplateRecord.filter(Column("id") == id && Column("built_in") == false).deleteAll($0) }
    }

    public func recipes() throws -> [Recipe] {
        try reader.read { try Recipe.order(Column("built_in").desc, Column("name")).fetchAll($0) }
    }

    public func saveRecipe(_ recipe: Recipe) throws {
        try writer.write { try recipe.save($0) }
    }

    public func deleteRecipe(_ id: String) throws {
        _ = try writer.write { try Recipe.filter(Column("id") == id && Column("built_in") == false).deleteAll($0) }
    }

    public func callApps() throws -> [CallApp] {
        try reader.read { try CallApp.order(Column("name")).fetchAll($0) }
    }

    public func saveCallApp(_ app: CallApp) throws {
        try writer.write { try app.save($0) }
    }
}
