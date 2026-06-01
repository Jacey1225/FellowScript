import Logger from '../logger/Logger';
/**
 * [[ZLIBTextCompressor]] Performs the text compression and decompression using zlib
 */
export default class ZLIBTextCompressor {
    private logger;
    private static Z_MEM_LEVEL;
    private static MAX_DICTIONARY_SIZE;
    /**
     * Constructs an instance of [[ZLIBTextCompressor]]
     * @param logger
     */
    constructor(logger: Logger);
    /**
     * Compresses the given text.
     *
     * Note: The dictionary used during compression should be the same as
     * that being used during decompression.
     *
     * @param text - the text that needs to be compressed
     * @param dictionary - that will be used to seed the compression
     *      library to improve compression's performance
     * @returns a compressed text
     */
    compress(text: string, dictionary: string): Uint8Array;
    /**
     * Decompresses the given text and returns the original text.
     *
     * Note: The dictionary used during compression should be the same as
     * that being used during decompression.
     *
     * @param compressedText that will be decompressed
     * @param dictionary that will be used to seed the compression library to improve
     *      decompression's performance
     * @returns decompressed string
     */
    decompress(compressedText: Uint8Array, dictionary: string): string;
}
