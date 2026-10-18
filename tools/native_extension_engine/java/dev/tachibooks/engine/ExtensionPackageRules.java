package dev.tachibooks.engine;

/** Library version gate observed in Tachimanga 5.0 build511 Extension.class. */
final class ExtensionPackageRules {
    static double libraryVersion(String declared, String versionName) {
        Double parsed = number(declared);
        if (parsed == null || parsed == 0) {
            String version = versionName == null ? "" : versionName;
            int separator = version.lastIndexOf('.');
            parsed = number(separator < 0 ? version : version.substring(0, separator));
        }
        if (parsed == null || Double.isNaN(parsed) || Double.isInfinite(parsed) || parsed < 1.3 || parsed > 1.6)
            throw new UnsupportedExtensionVersionException();
        return parsed;
    }
    private static Double number(String value) {
        if (value == null) return null;
        try {
            return Double.parseDouble(value);
        } catch (NumberFormatException invalid) { return null; }
    }
}

final class UnsupportedExtensionVersionException extends IllegalArgumentException {
    UnsupportedExtensionVersionException() {
        super("Extension library version must be between 1.3 and 1.6");
    }
}
