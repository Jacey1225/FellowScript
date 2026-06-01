"use strict";
// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0
Object.defineProperty(exports, "__esModule", { value: true });
/**
 * A simple promise queue to enforce the order of async APIs for example, start/stop video/audio input.
 */
class PromiseQueue {
    constructor() {
        this.queue = Promise.resolve();
    }
    // eslint-disable-next-line
    add(func) {
        return new Promise((resolve, reject) => {
            this.queue = this.queue.then(func).then(resolve).catch(reject);
        });
    }
}
exports.default = PromiseQueue;
//# sourceMappingURL=PromiseQueue.js.map