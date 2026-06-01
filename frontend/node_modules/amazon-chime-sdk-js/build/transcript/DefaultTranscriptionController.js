"use strict";
// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0
Object.defineProperty(exports, "__esModule", { value: true });
exports.TRANSCRIPTION_DATA_MESSAGE_TOPIC = void 0;
const TranscriptEvent_1 = require("./TranscriptEvent");
exports.TRANSCRIPTION_DATA_MESSAGE_TOPIC = 'aws:chime:transcription';
class DefaultTranscriptionController {
    constructor(realtimeController) {
        this.realtimeController = realtimeController;
        this.transcriptEventCallbacks = new Set();
    }
    subscribeToTranscriptEvent(callback) {
        if (this.transcriptEventCallbacks.size === 0) {
            this.realtimeController.realtimeSubscribeToReceiveDataMessage(exports.TRANSCRIPTION_DATA_MESSAGE_TOPIC, (dataMessage) => {
                for (const transcriptEvent of TranscriptEvent_1.TranscriptEventConverter.from(dataMessage)) {
                    for (const transcriptEventCallback of this.transcriptEventCallbacks) {
                        transcriptEventCallback(transcriptEvent);
                    }
                }
            });
        }
        this.transcriptEventCallbacks.add(callback);
    }
    unsubscribeFromTranscriptEvent(callback) {
        this.transcriptEventCallbacks.delete(callback);
        if (this.transcriptEventCallbacks.size === 0) {
            this.realtimeController.realtimeUnsubscribeFromReceiveDataMessage(exports.TRANSCRIPTION_DATA_MESSAGE_TOPIC);
        }
    }
}
exports.default = DefaultTranscriptionController;
//# sourceMappingURL=DefaultTranscriptionController.js.map