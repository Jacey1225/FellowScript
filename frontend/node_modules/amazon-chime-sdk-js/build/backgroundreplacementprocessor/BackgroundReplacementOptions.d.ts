import BackgroundFilterOptions from '../backgroundfilter/BackgroundFilterOptions';
/**
 * A set of options that can be supplied when creating a background replacement video frame processor.
 */
export default interface BackgroundReplacementOptions extends BackgroundFilterOptions {
    /** The image to replace the background with */
    imageBlob?: Blob;
}
