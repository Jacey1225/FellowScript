import ModelShape from './ModelShape';
/**
 * An interface for defining the input and output shape of a ML model along with the path
 * to download the model.
 */
export default interface ModelSpec {
    path: string;
    input: ModelShape;
    output: ModelShape;
}
