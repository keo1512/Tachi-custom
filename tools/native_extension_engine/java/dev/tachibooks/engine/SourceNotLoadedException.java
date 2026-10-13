package dev.tachibooks.engine;

/** A restored reference cannot be used before its source extension is loaded. */
final class SourceNotLoadedException extends IllegalArgumentException {
    SourceNotLoadedException() { super("Required source extension is not loaded."); }
}
