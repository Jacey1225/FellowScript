"use strict";
// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0
Object.defineProperty(exports, "__esModule", { value: true });
/**
 * This class adds the functionality to allow for a set of unique observers to be added to the
 * video frame processor.
 */
/** @internal */
class BackgroundFilterVideoFrameProcessorDelegate {
    constructor() {
        this.observers = new Set();
    }
    /**
     * Add an observer to the unique set. If a duplicate observer cannot be added.
     * @param observer An implementation of the observer interface.
     */
    addObserver(observer) {
        this.observers.add(observer);
    }
    /**
     * Remove the observer from the set of observers.
     * @param observer An implementation of the observer interface.
     */
    removeObserver(observer) {
        this.observers.delete(observer);
    }
    /**
     * Call the observer method with the event information. See [[BackgroundFilterVideoFrameProcessorObserver]]
     * for detailed info on this event.
     * @param event
     */
    filterFrameDurationHigh(event) {
        var _a;
        for (const observer of this.observers) {
            (_a = observer.filterFrameDurationHigh) === null || _a === void 0 ? void 0 : _a.call(observer, event);
        }
    }
    filterCPUUtilizationHigh(event) {
        var _a;
        for (const observer of this.observers) {
            (_a = observer.filterCPUUtilizationHigh) === null || _a === void 0 ? void 0 : _a.call(observer, event);
        }
    }
}
exports.default = BackgroundFilterVideoFrameProcessorDelegate;
//# sourceMappingURL=BackgroundFilterVideoFrameProcessorDelegate.js.map