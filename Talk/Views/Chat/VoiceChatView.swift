//
//  VoiceChatView.swift
//  Talk
//
//  Created by Yu on 2025/4/6.
//

import Alamofire
import AVFoundation
import Combine
import SwiftData
import SwiftUI
import WhisperKit

struct VoiceChatView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var speechMonitor = SpeechMonitorViewModel()
    @Query private var settings: [SettingsModel]

    @State private var showingErrorAlert = false
    @State private var errorMessage = ""

    @State private var speechRecognitionService: SpeechRecognitionService?
    @State private var llmService: LLMService?
    @State private var ttsService: TTSService?

    @State private var servicesInitialed: Bool = false
    @State private var prepareForSpeak: Bool = false

    @State private var responding: Bool = false

    @State private var showingChatHistory = false

    private var currentSettings: SettingsModel? {
        settings.first
    }

    var body: some View {
        let colorCircle = ColorCircle(
            listening: speechMonitor.listening,
            speaking: speechMonitor.speaking,
            responding: responding,
            audioLevel: speechMonitor.voiceVolume
        ) {
            // Validate service initialization when user taps
            verifyAndInitializeServices()
        }

        ZStack {
            colorCircle
                .scaleEffect(showingChatHistory ? 0 : 1)
                .animation(.spring, value: showingChatHistory)
                .onChange(of: speechMonitor.recordedAudioData) { _, newValue in
                    onSpeakEnd(data: newValue)
                }
                .onChange(of: currentSettings?.settingsHash) { _, _ in
                    debugPrint("Settings changed")
                    if speechMonitor.listening {
                        speechMonitor.stopMonitoring()
                    }

                    servicesInitialed = false
                }
                .alert("Configuration Information", isPresented: $showingErrorAlert) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(errorMessage)
                }

            VStack {
                Spacer()

                HStack {
                    Spacer()

                    Button {
                        showingChatHistory.toggle()
                    } label: {
                        Image(systemName: "archivebox.fill")
                            .foregroundColor(ColorTheme.backgroundColor())
                            .padding(8)
                            .background(
                                Circle()
                                    .fill(ColorTheme.textColor())
                            )
                    }
                }
            }
            .sheet(isPresented: $showingChatHistory) {
                ChatHistoryView {
                    colorCircle
                        .scaleEffect(0.7)
                }
            }
        }
    }

    private func verifyAndInitializeServices() {
        if responding {
            return
        }

        prepareForSpeak = true

        Task {
            if !servicesInitialed {
                servicesInitialed = await initializeServices()
                if !servicesInitialed {
                    prepareForSpeak = false
                    return
                }
            }
            speechMonitor.toggleMonitoring()

            prepareForSpeak = false
        }
    }

    @discardableResult
    private func initializeServices() async -> Bool {
        do {
            guard let currentSettings else {
                throw SettingsServiceError.invalidConfiguration("Please open the settings page to configure your preferences for the first time.")
            }

            let manualRecording = currentSettings.selectedRecordingMode == .manual
            speechMonitor.setManualRecording(manualRecording)

            speechRecognitionService = try await ServicesManager.createSpeechRecognitionService(
                selectedSpeechService: currentSettings.selectedSpeechService,
                whisperCppSettings: currentSettings.whisperCppSettings,
                whisperKitSettings: currentSettings.whisperKitSettings,
                appleSpeechSettings: currentSettings.appleSpeechSettings
            )

            llmService = try ServicesManager.createLLMService(
                selectedLLMService: currentSettings.selectedLLMService,
                openAILLMSettings: currentSettings.openAILLMSettings,
                difySettings: currentSettings.difySettings
            )

            ttsService = try ServicesManager.createTTSService(
                selectedTTSService: currentSettings.selectedTTSService,
                microsoftTTSSettings: currentSettings.microsoftTTSSettings,
                openAITTSSettings: currentSettings.openAITTSSettings,
                systemTTSSettings: currentSettings.systemTTSSettings
            )

            return true
        } catch let SettingsServiceError.invalidConfiguration(message) {
            showErrorAlert(message)
            return false
        } catch {
            showErrorAlert("Unknown error occurred: \(error.localizedDescription)")
            return false
        }
    }

    private func showErrorAlert(_ message: String) {
        errorMessage = message
        showingErrorAlert = true
    }

    func onSpeakEnd(data: [Int16]?) {
        guard let data else {
            print("No audio data")
            return
        }

        guard let currentSettings else {
            print("No Settings")
            return
        }

        guard let speechRecognitionService = speechRecognitionService,
              let llmService = llmService,
              let ttsService = ttsService
        else {
            showErrorAlert("Services not properly initialized")
            return
        }

        if currentSettings.selectedRecordingMode == .auto {
            speechMonitor.stopMonitoring()
        }

        Task {
            do {
                responding = true

                let sttText = try await speechRecognitionService.recognizeSpeech(pcmData: data).text

                ChatHistory.addMessage(content: sttText, isUserMessage: true, in: modelContext)

                var chatHistoryMessages = ChatHistory.getLatestMessages(count: 5, in: modelContext)
                    .map {
                        LLMMessage(
                            content: $0.content,
                            role: $0.isUserMessage ? "user" : "assistant"
                        )
                    }

                let modelName: String
                switch currentSettings.selectedLLMService {
                case .openAI:
                    modelName = currentSettings.openAILLMSettings.model
                case .dify:
                    modelName = ""
                }

                var additionalParams: [String: Any] = [:]

                let useOpenAILLM = currentSettings.selectedLLMService == .openAI
                let openAILLMPromptEmpty = currentSettings.openAILLMSettings.prompt.isEmpty

                if useOpenAILLM {
                    if !openAILLMPromptEmpty {
                        chatHistoryMessages.insert(
                            LLMMessage(content: currentSettings.openAILLMSettings.prompt, role: "system"),
                            at: 0
                        )
                    }
                    additionalParams["temperature"] = currentSettings.openAILLMSettings.temperature
                    additionalParams["top_p"] = currentSettings.openAILLMSettings.top_p
                }

                let request = LLMRequest(
                    messages: chatHistoryMessages,
                    model: modelName,
                    additionalParams: additionalParams
                )

                let llmResponse = try await llmService.sendMessage(request)

                ChatHistory.addMessage(content: llmResponse.content, isUserMessage: false, in: modelContext)

                let playback = try await ttsService.speak(llmResponse.content)
                await playback.waitForCompletion()

                responding = false

                if currentSettings.selectedRecordingMode == .auto {
                    speechMonitor.startMonitoring()
                }
            } catch {
                print(error)
                responding = false
                showErrorAlert("Error during conversation: \(error.localizedDescription)")
            }
        }
    }
}

#Preview("VoiceChatView") {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: SettingsModel.self, ChatMessage.self, configurations: config)

    let context = container.mainContext
    if try! context.fetch(FetchDescriptor<SettingsModel>()).isEmpty {
        context.insert(SettingsModel())
    }

    return VoiceChatView()
        .modelContainer(container)
}
