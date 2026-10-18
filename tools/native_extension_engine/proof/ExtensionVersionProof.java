package dev.tachibooks.engine;

/** Boundaries verified against original build511 Extension.validateExtensionPackage. */
public final class ExtensionVersionProof {
    private static int assertions;
    private static void accept(String metadata,String name,double expected) {
        assertions++;
        if(ExtensionPackageRules.libraryVersion(metadata,name)!=expected)throw new AssertionError("Wrong library version selection");
    }
    private static void reject(String metadata,String name) {
        assertions++;
        try{ExtensionPackageRules.libraryVersion(metadata,name);throw new AssertionError("Unsupported version accepted");}
        catch(UnsupportedExtensionVersionException expected){}
    }
    public static void main(String[] args) {
        accept(null,"1.3.42",1.3);accept(null,"1.6.71",1.6);
        accept("1.4","5.0.1",1.4);accept("0","1.6.71",1.6);
        accept("invalid","1.5.2",1.5);
        reject(null,"1.4");reject(null,null);reject(null,"nonsense");
        reject("1.2","1.6.71");reject("1.7","1.6.71");
        reject("NaN","1.6.71");reject("Infinity","1.6.71");
        System.out.println("EXTENSION_VERSION_PROOF_OK assertions="+assertions);
    }
}
