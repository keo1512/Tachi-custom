package com.squareup.zstd.okio;

import io.airlift.compress.zstd.ZstdCompressor;
import io.airlift.compress.zstd.ZstdInputStream;
import java.io.IOException;
import okio.*;

/** Portable implementation of the Square Okio Zstandard facade's public ABI. */
public final class OkioZstd {
    private static final byte[] EMPTY=new byte[0];
    private static final int CHUNK_BYTES=64*1024;
    private OkioZstd(){}
    public static byte[] getEmptyByteArray(){return EMPTY;}
    public static Sink zstdCompress(Sink destination){return new FrameSink(destination);}
    public static Source zstdDecompress(Source input){
        if(input==null)throw new NullPointerException("Source is required");
        final Source decoder=Okio.source(new ZstdInputStream(Okio.buffer(input).inputStream()));
        return new Source(){
            public long read(Buffer sink,long count)throws IOException{if(count<0)throw new IllegalArgumentException("Negative byte count");input.timeout().throwIfReached();return decoder.read(sink,count);}
            public Timeout timeout(){return input.timeout();}
            public void close()throws IOException{decoder.close();}
        };
    }
    /** Each bounded input chunk becomes a complete, standard concatenated Zstd frame.
     * No bytes are retained across flush, and close still emits a valid empty stream. */
    private static final class FrameSink implements Sink{
        private final Sink destination;
        private final ZstdCompressor compressor=new ZstdCompressor();
        private final byte[] input=new byte[CHUNK_BYTES];
        private final byte[] output=new byte[compressor.maxCompressedLength(CHUNK_BYTES)];
        private boolean closed,wrote;
        FrameSink(Sink destination){if(destination==null)throw new NullPointerException("Sink is required");this.destination=destination;}
        public void write(Buffer source,long count)throws IOException{
            if(closed)throw new IOException("Compression sink is closed");
            if(count<0||count>source.size())throw new IllegalArgumentException("Invalid compression byte count");
            while(count>0){
                destination.timeout().throwIfReached();int size=(int)Math.min(count,CHUNK_BYTES),offset=0;
                while(offset<size){int read=source.read(input,offset,size-offset);if(read<1)throw new IOException("Unexpected end of compression input");offset+=read;}
                writeFrame(size);count-=size;
            }
        }
        private void writeFrame(int count)throws IOException{
            int size=compressor.compress(input,0,count,output,0,output.length);
            Buffer buffer=new Buffer().write(output,0,size);destination.write(buffer,size);wrote=true;
        }
        public void flush()throws IOException{if(closed)throw new IOException("Compression sink is closed");destination.flush();}
        public Timeout timeout(){return destination.timeout();}
        public void close()throws IOException{
            if(closed)return;
            try{if(!wrote)writeFrame(0);}finally{closed=true;destination.close();}
        }
    }
}
