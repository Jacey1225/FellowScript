"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.tail = tail;
exports.last = last;
exports.sequenceEquals = sequenceEquals;
exports.pushToStart = pushToStart;
exports.pushToEnd = pushToEnd;
exports.firstIndex = firstIndex;
exports.remove = remove;
function tail(arr) {
    if (arr.length === 0) {
        throw new Error('Invalid tail call');
    }
    return [arr.slice(0, arr.length - 1), arr[arr.length - 1]];
}
function last(arr) {
    return arr.length > 0 ? arr[arr.length - 1] : undefined;
}
function sequenceEquals(arr1, arr2) {
    if (arr1.length !== arr2.length) {
        return false;
    }
    for (var i = 0; i < arr1.length; i++) {
        if (arr1[i] !== arr2[i]) {
            return false;
        }
    }
    return true;
}
/**
 * Pushes an element to the start of the array, if found.
 */
function pushToStart(arr, value) {
    var index = arr.indexOf(value);
    if (index > -1) {
        arr.splice(index, 1);
        arr.unshift(value);
    }
}
/**
 * Pushes an element to the end of the array, if found.
 */
function pushToEnd(arr, value) {
    var index = arr.indexOf(value);
    if (index > -1) {
        arr.splice(index, 1);
        arr.push(value);
    }
}
function firstIndex(array, fn) {
    for (var i = 0; i < array.length; i++) {
        var element = array[i];
        if (fn(element)) {
            return i;
        }
    }
    return -1;
}
function remove(array, value) {
    var index = array.findIndex(function (t) { return t === value; });
    if (index > -1) {
        array.splice(index, 1);
        return true;
    }
    return false;
}
