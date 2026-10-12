package dev.tachibooks.engine;

import java.io.IOException;

/** A protected source needs a real browser session supplied by the native host. */
public final class BrowserChallengeException extends IOException {
    public BrowserChallengeException() { super("The source requires an interactive browser session."); }
}
