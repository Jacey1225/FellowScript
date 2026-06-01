/**
 * Represents parsed attributes of a media section (i.e. associated with a single m-line)
 */
export default class SDPMediaSection {
    mediaType: 'audio' | 'video';
    mid: string;
    direction: RTCRtpTransceiverDirection;
}
