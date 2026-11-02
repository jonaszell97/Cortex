/// Every module, in the order they start. The only place in App/ and Host/
/// that names a module.
enum ModuleList {
    static let all: [any CortexModule.Type] = [
        ClipboardModule.self,
        SnippetsModule.self,
        ReadingListModule.self,
        KnowledgeModule.self,
        ActionsModule.self,
        CommandsModule.self,
        AIModule.self,
        EmojiModule.self,
        CalculatorModule.self,
        SymbolsModule.self,
        ColorPickerModule.self,
        TextRecognitionModule.self,
        ScrollingModule.self,
        SyncModule.self,
    ]
}
