"use strict";
// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0
Object.defineProperty(exports, "__esModule", { value: true });
exports.None = exports.Some = exports.Maybe = void 0;
class Maybe {
    static of(value) {
        return value === undefined || value === null ? None.of() : Some.of(value);
    }
}
exports.Maybe = Maybe;
class Some {
    constructor(value) {
        this.value = value;
        this.isSome = true;
        this.isNone = false;
    }
    map(f) {
        return Maybe.of(f(this.value));
    }
    flatMap(f) {
        return f(this.value);
    }
    get() {
        return this.value;
    }
    getOrElse(_value) {
        return this.value;
    }
    defaulting(value) {
        return Maybe.of(this.getOrElse(value));
    }
    static of(value) {
        if (value === null || value === undefined) {
            throw new Error('value is ${value}');
        }
        return new Some(value);
    }
}
exports.Some = Some;
class None {
    constructor() {
        this.isSome = false;
        this.isNone = true;
    }
    get() {
        throw new Error('value is null');
    }
    getOrElse(value) {
        return value;
    }
    map(_f) {
        return new None();
    }
    flatMap(_f) {
        return new None();
    }
    defaulting(value) {
        return Maybe.of(this.getOrElse(value));
    }
    static of() {
        return new None();
    }
}
exports.None = None;
//# sourceMappingURL=Types.js.map