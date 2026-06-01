"use strict";
// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0
Object.defineProperty(exports, "__esModule", { value: true });
/**
 *
 * @param attributes Event attributes to flatten.
 * @returns flattened event attributes.
 * Note: This function needs to be extended to support 'Array', 'object'
 * as value types within the event attributes if added later.
 */
const flattenEventAttributes = (attributes) => {
    const flattenedAttributes = {};
    for (const [key, value] of Object.entries(attributes)) {
        if (value === null || value === undefined || value === '') {
            continue;
        }
        else if (typeof value === 'number' || typeof value === 'string') {
            flattenedAttributes[key] = value;
        }
        else {
            throw new TypeError('Unhandled type received while flattening attributes.');
        }
    }
    return flattenedAttributes;
};
exports.default = flattenEventAttributes;
//# sourceMappingURL=flattenEventAttributes.js.map