"use strict";
// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0
Object.defineProperty(exports, "__esModule", { value: true });
/**
 * [[IntervalScheduler]] calls the callback every intervalMs milliseconds.
 */
class IntervalScheduler {
    constructor(intervalMs) {
        this.intervalMs = intervalMs;
    }
    start(callback) {
        this.stop();
        this.timer = setInterval(callback, this.intervalMs);
    }
    stop() {
        if (this.timer === undefined) {
            return;
        }
        clearInterval(this.timer);
        this.timer = undefined;
    }
    running() {
        return this.timer !== undefined;
    }
}
exports.default = IntervalScheduler;
//# sourceMappingURL=IntervalScheduler.js.map