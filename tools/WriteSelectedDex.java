import java.io.File;
import java.nio.file.*;
import java.util.*;
import org.jf.dexlib2.*;
import org.jf.dexlib2.iface.*;
import org.jf.dexlib2.writer.pool.DexPool;

/** 保留原始方法指令，按原 dex 分组写出所选类，避免单 dex 引用数溢出。 */
public final class WriteSelectedDex {
    public static void main(String[] args) throws Exception {
        Set<String> names=new HashSet<>(Files.readAllLines(Paths.get(args[0])));
        File out=new File(args[1]);out.mkdirs();
        int index=0;
        for(int i=2;i<args.length;i++) {
            DexFile dex=DexFileFactory.loadDexFile(new File(args[i]),Opcodes.getDefault());
            DexPool pool=new DexPool(dex.getOpcodes());int count=0;
            for(ClassDef cls:dex.getClasses()) if(names.contains(cls.getType())) {pool.internClass(cls);count++;}
            if(count>0) {index++;pool.writeTo(new org.jf.dexlib2.writer.io.FileDataStore(new File(out,"classes"+(index==1?"":index)+".dex")));}
        }
    }
}
