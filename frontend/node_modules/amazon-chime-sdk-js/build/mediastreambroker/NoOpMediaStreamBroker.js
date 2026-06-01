"use strict";
// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0
Object.defineProperty(exports, "__esModule", { value: true });
/**
 * [[NoOpDeviceBroker]] rejects requests to acquire a [[MediaStream]].
 */
class NoOpMediaStreamBroker {
    acquireAudioInputStream() {
        return Promise.reject();
    }
    acquireVideoInputStream() {
        return Promise.reject();
    }
    acquireDisplayInputStream(_streamConstraints) {
        return Promise.reject();
    }
    muteLocalAudioInputStream() { }
    unmuteLocalAudioInputStream() { }
    addMediaStreamBrokerObserver(_observer) { }
    removeMediaStreamBrokerObserver(_observer) { }
}
exports.default = NoOpMediaStreamBroker;
//# sourceMappingURL=NoOpMediaStreamBroker.js.map