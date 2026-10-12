import eu.kanade.tachiyomi.source.CatalogueSource;
import eu.kanade.tachiyomi.source.model.*;
import java.util.*;
import java.util.concurrent.*;
import kotlin.ResultKt;
import kotlin.coroutines.*;
import kotlin.coroutines.intrinsics.IntrinsicsKt;
import rx.Observable;

/** Offline executable regression for the compiled source API and its Rx bridge. */
public final class SourceApiProof {
    private interface Operation<T> { Object run(Continuation<T> completion); }
    private static final class Completion<T> implements Continuation<T> {
        final CountDownLatch finished = new CountDownLatch(1);
        Object value;
        public CoroutineContext getContext() { return EmptyCoroutineContext.INSTANCE; }
        public void resumeWith(Object result) { value = result; finished.countDown(); }
    }
    @SuppressWarnings("unchecked")
    private static <T> T await(Operation<T> operation) throws Exception {
        Completion<T> completion = new Completion<>();
        Object result = operation.run(completion);
        if (result != IntrinsicsKt.getCOROUTINE_SUSPENDED()) return (T) result;
        if (!completion.finished.await(10, TimeUnit.SECONDS)) throw new AssertionError("Coroutine did not finish");
        ResultKt.throwOnFailure(completion.value);
        return (T) completion.value;
    }
    private static void require(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
    private static SManga manga(String title) {
        SManga manga = SManga.Companion.create();
        manga.setUrl("/manga/" + title);
        manga.setTitle(title);
        return manga;
    }
    private static final class LegacySource implements CatalogueSource {
        volatile int detailCalls, chapterCalls;
        public long getId() { return 2553532324170433933L; }
        public String getName() { return "Offline legacy fixture"; }
        public String getLang() { return "vi"; }
        public boolean getSupportsLatest() { return true; }
        public Observable<MangasPage> fetchSearchManga(int page, String query, FilterList filters) {
            return Observable.just(new MangasPage(Collections.singletonList(manga(query)), page == 1));
        }
        public Observable<SManga> fetchMangaDetails(SManga old) {
            detailCalls++;
            return Observable.just(manga("updated"));
        }
        public Observable<List<SChapter>> fetchChapterList(SManga old) {
            chapterCalls++;
            SChapter chapter = SChapter.Companion.create();
            chapter.setUrl("/chapter/stable"); chapter.setName("Chapter 1");
            return Observable.just(Collections.singletonList(chapter));
        }
        public Observable<List<Page>> fetchPageList(SChapter chapter) {
            return Observable.just(Collections.singletonList(new Page(0, chapter.getUrl(), "https://fixture.invalid/page.png", null)));
        }
    }
    public static void main(String[] args) throws Exception {
        require(System.getProperty("java.specification.version").equals("1.8"), "Proof must execute on Java8");
        LegacySource legacy = new LegacySource();
        MangasPage search = await(done -> legacy.getSearchManga(1, "stable", legacy.getFilterList(), done));
        require(search.getMangas().get(0).getTitle().equals("stable") && search.getHasNextPage(), "Legacy Rx search bridge");
        SManga initial = manga("initial");
        require(initial.getMemo().isEmpty(), "Modern SManga memo default");
        List<SChapter> chapters = Collections.emptyList();
        SMangaUpdate unchanged = await(done -> legacy.getMangaUpdate(initial, chapters, false, false, done));
        require(unchanged.getManga() == initial && unchanged.getChapters() == chapters, "Unrequested update must preserve inputs");
        require(legacy.detailCalls == 0 && legacy.chapterCalls == 0, "Disabled update flags must skip requests");
        SMangaUpdate changed = await(done -> legacy.getMangaUpdate(initial, chapters, true, true, done));
        require(changed.getManga().getTitle().equals("updated") && changed.getChapters().size() == 1, "Combined suspend update");
        require(legacy.detailCalls == 1 && legacy.chapterCalls == 1, "Requested update dispatch");
        List<? extends Page> pages = await(done -> legacy.getPageList(changed.getChapters().get(0), done));
        require(pages.get(0).getImageUrl().equals("https://fixture.invalid/page.png"), "Legacy page bridge");
        require(Long.toString(legacy.getId()).equals("2553532324170433933"), "64bit source ID");
        for (String name : new String[] {
                "eu.kanade.tachiyomi.source.online.HttpSource",
                "eu.kanade.tachiyomi.source.online.ParsedHttpSource",
                "eu.kanade.tachiyomi.network.OkHttpExtensionsKt",
                "eu.kanade.tachiyomi.network.interceptor.RateLimitInterceptorKt"}) {
            Class.forName(name, false, SourceApiProof.class.getClassLoader());
        }
        System.out.println("JAVA8_SOURCE_API_PROOF_OK search/update flags/pages/memo/64bit ID/class loading");
    }
}
