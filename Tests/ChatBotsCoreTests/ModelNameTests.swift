// ChatBotsCoreTests — what a model is called on screen

import ChatBotsCore
import Testing

@Suite("Model names")
struct ModelNameTests {

    @Test("DeepSeek models are called what DeepSeek calls them")
    func deepSeekNames() {
        #expect(ModelNames.friendly("deepseek-v4-flash") == "DeepSeek V4.1 Flash")
        #expect(ModelNames.friendly("deepseek-v4.1-flash") == "DeepSeek V4.1 Flash")
        #expect(ModelNames.friendly("deepseek-v4-pro") == "DeepSeek V4.1 Pro")
        #expect(ModelNames.friendly("deepseek-chat") == "DeepSeek Chat")
        #expect(ModelNames.friendly("deepseek-reasoner") == "DeepSeek Reasoner")
    }

    @Test("A server prefix does not change the name")
    func serverPrefixIsIgnored() {
        // The same model reached through different servers must not be labelled differently.
        #expect(ModelNames.friendly("deepseek/deepseek-v4-flash") == "DeepSeek V4.1 Flash")
        #expect(ModelNames.friendly("some-host/deepseek-v4-pro") == "DeepSeek V4.1 Pro")
    }

    @Test("Other well-known families get their proper names")
    func otherFamilies() {
        #expect(ModelNames.friendly("gpt-4o") == "GPT-4o")
        #expect(ModelNames.friendly("gpt-4o-mini") == "GPT-4o mini")
        #expect(ModelNames.friendly("claude-sonnet-4") == "Claude Sonnet 4")
        #expect(ModelNames.friendly("gemini-2.5-flash") == "Gemini 2.5 Flash")
    }

    @Test("An unknown model is tidied up rather than shown raw")
    func unknownModelsAreReadable() {
        // A model the app has never heard of still gets a label, because a blank or a raw
        // slug in the header is worse than a guess at capitalisation.
        #expect(ModelNames.friendly("llama-3-8b-instruct") == "Llama 3 8b Instruct")
        #expect(ModelNames.friendly("my_org/mistral_7b.base") == "Mistral 7b Base")
        #expect(ModelNames.friendly("a-model") == "A Model")
    }

    @Test("A seat reports the friendly name, whichever backend it uses")
    func seatLabels() {
        var api = AgentSpec.seat(index: 0)
        api.backend = .openAIResponses
        api.openAI.model = "deepseek-v4-flash"
        // The header, the settings sheet and the web interface all read one of these two, so
        // they cannot disagree about what the model is called.
        #expect(api.backendLabel == "DeepSeek V4.1 Flash")
        #expect(api.modelLabel == "DeepSeek V4.1 Flash")

        var local = AgentSpec.seat(index: 1)
        local.backend = .mlx
        // The local checkpoint's own naming is already friendly and is left alone.
        #expect(local.backendLabel == "Qwen3.5-4B-4bit")
    }
}
