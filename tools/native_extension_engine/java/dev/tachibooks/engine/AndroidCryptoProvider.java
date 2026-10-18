package dev.tachibooks.engine;

import java.security.Provider;
import java.security.Security;

/** Official signed provider, including Android AES/PKCS7 transformation names.
 * Register last so existing JRE TLS and cipher choices keep precedence.
 */
final class AndroidCryptoProvider {
    static synchronized void install()throws ReflectiveOperationException{
        if(Security.getProvider("BC")!=null)return;
        try{
            Provider provider=(Provider)Class.forName("org.bouncycastle.jce.provider.BouncyCastleProvider").getDeclaredConstructor().newInstance();
            Security.addProvider(provider);
        }catch(ClassNotFoundException legacyHost){
            // Historical host-only proofs can omit this separate signed JAR.
            // Current app packaging requires its pinned bytes and provenance.
        }
    }
}
