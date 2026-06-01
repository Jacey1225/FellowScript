"use strict";
// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0
Object.defineProperty(exports, "__esModule", { value: true });
/**
 * [[MeetingEventsClientConfiguration]] contains necessary information to
 * report meeting events metadata to each event while sending events to the ingestion service.
 */
class MeetingEventsClientConfiguration {
    constructor(meetingId, attendeeId, authenticationToken, eventsToIgnore = []) {
        this.type = 'Meet';
        this.v = 1;
        this.meetingId = meetingId;
        this.attendeeId = attendeeId;
        this.eventsToIgnore = eventsToIgnore;
        this.authenticationToken = authenticationToken;
    }
    getAuthenticationToken() {
        return this.authenticationToken;
    }
    toJSON() {
        const attributes = {};
        attributes.type = this.type;
        attributes.v = this.v;
        attributes.meetingId = this.meetingId;
        attributes.attendeeId = this.attendeeId;
        return attributes;
    }
}
exports.default = MeetingEventsClientConfiguration;
//# sourceMappingURL=MeetingEventsClientConfiguration.js.map