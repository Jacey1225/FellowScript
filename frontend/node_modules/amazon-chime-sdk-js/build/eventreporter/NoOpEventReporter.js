"use strict";
// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0
Object.defineProperty(exports, "__esModule", { value: true });
class NoOpEventReporter {
    constructor() { }
    reportEvent(_ts, _name, _attributes) {
        return;
    }
    start() { }
    stop() { }
}
exports.default = NoOpEventReporter;
//# sourceMappingURL=NoOpEventReporter.js.map