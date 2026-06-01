"use strict";
// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0
Object.defineProperty(exports, "__esModule", { value: true });
/**
 * [[EventBufferConfiguration]] contains necessary information to
 * configure buffer.
 */
class EventBufferConfiguration {
    constructor(flushIntervalMs = 5000, flushSize = 2, maxBufferCapacityKb = 64, totalBufferItems = 100, retryCountLimit = 15) {
        this.flushIntervalMs = flushIntervalMs;
        this.flushSize = flushSize;
        this.maxBufferCapacityKb = maxBufferCapacityKb;
        this.totalBufferItems = totalBufferItems;
        this.retryCountLimit = retryCountLimit;
    }
}
exports.default = EventBufferConfiguration;
//# sourceMappingURL=EventBufferConfiguration.js.map