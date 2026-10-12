import com.googlecode.d2j.dex.Dex2jar;
import dev.tachibooks.engine.DexCompatibility;
import java.io.File;
import java.nio.file.Paths;

/** Explicit diagnostic converter; original APK is read without modification. */
public final class ConvertPrepared {
    public static void main(String[] args) throws Exception {
        Dex2jar source = Dex2jar.from(new File(args[0]));
        Dex2jar.from(DexCompatibility.prepare(source.getReader()))
                .skipDebug().dontSanitizeNames(true).computeFrames(true).to(Paths.get(args[1]));
    }
}
