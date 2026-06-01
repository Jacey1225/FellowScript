"use strict";
// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0
Object.defineProperty(exports, "__esModule", { value: true });
exports.BlurStrengthMapper = void 0;
/**
 * The numbers below indicate the amount of blur to apply. Larger numbers will produce
 * more blur.
 */
const BlurStrength = {
    LOW: 7,
    MEDIUM: 15,
    HIGH: 30,
};
/** @internal */
class BlurStrengthMapper {
    static getBlurAmount(bstrength, options) {
        if (bstrength <= 0) {
            throw new Error(`invalid value for blur strength: ${bstrength}`);
        }
        return Math.round((bstrength * options.height) / this.BLUR_STRENGTH_DIVISOR);
    }
}
exports.BlurStrengthMapper = BlurStrengthMapper;
BlurStrengthMapper.BLUR_STRENGTH_DIVISOR = 540; // use 540P as baseline blur strength
exports.default = BlurStrength;
//# sourceMappingURL=BackgroundBlurStrength.js.map