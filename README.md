# Dynamic Island for macOS

MacBook çentiğiyle fiziksel olarak hizalanan, SwiftUI ile yazılmış yerel bir macOS Dynamic Island uygulaması.

## Özellikler

- Gerçek çentik geometrisini `NSScreen.auxiliaryTopLeftArea` ve `auxiliaryTopRightArea` ile algılar; boşta tamamen fiziksel çentiğin arkasına gizlenir.
- Chrome/YouTube, Safari, Arc, Music ve Spotify dahil macOS “Şu An Çalıyor” oturumundaki medyanın gerçek kapağını, geçen/kalan süresini ve canlı ilerleme çizgisini gösterir.
- Sistem genelinde oynat/duraklat, önceki/sonraki parça, ±15 saniye sarma ve ilerleme çizgisinden konum değiştirme denetimleri sunar.
- Medya etkinken adaya tıklamak doğrudan Medya görünümünü, boşta tıklamak genel menüyü açar; ada dışına tıklamak geniş görünümü kapatır.
- macOS bildirim banner'larını uygulama simgesi, başlık ve içerikle Dynamic Island'da gösterir; art arda gelen bildirimleri sıraya alır ve adaya tıklanınca gerçek bildirim eylemini veya kaynak uygulamayı açar.
- Geri sayım, kronometre ve 25 dakikalık odak oturumu içerir.
- macOS Saat uygulamasında çalışan timer'ları `mobiletimerd` verisinden salt-okunur olarak canlı gösterir.
- Sayaç bittiğinde yerel ses ve macOS bildirimi verir.
- CoreAudio ile klavye, AirPods ve Denetim Merkezi ses değişikliklerini; solda ses değeri, sağda düz beyaz seviye çubuğu olacak biçimde yatay Dynamic Island HUD'u olarak gösterir.
- Yerleşik ekranın klavye veya Denetim Merkezi üzerinden değişen parlaklığını aynı yatay düzende; solda güneş simgesi/yüzde, sağda düz beyaz seviye çubuğuyla gösterir.
- Sistem görünümündeki Wi‑Fi ve Bluetooth kartları açılır bağlantı panelleridir: radyoları açıp kapatır, yakındaki Wi‑Fi ağlarını ve eşleşmiş Bluetooth aygıtlarını listeler, bağlantı kurar veya keser.
- Özet görünümündeki Wi‑Fi durumuna tıklamak doğrudan Sistem bölümündeki Wi‑Fi bağlantı panelini açar.
- Pil kartındaki Düşük Güç düğmesi macOS güç tasarrufu modunu açıp kapatır; pil, şarj, ağ ve sistem çıkış sesi durumunu gösterir.
- Tüm masaüstlerinde ve tam ekran uygulamaların üzerinde çalışır.
- Menü çubuğu simgesi ve `⌥ Boşluk` global kısayolu içerir.
- Çentiksiz ekranlarda ekranın üst-orta noktasında çalışmaya devam eder.

## Gereksinimler

- macOS 14 Sonoma veya daha yeni
- Apple Silicon veya Intel Mac (Universal 2 paket)
- Xcode 16 veya daha yeni / Swift 6 araç zinciri

## Derleme ve çalıştırma

```bash
make app
open "dist/Dynamic Island.app"
```

Geliştirme sırasında doğrudan çalıştırmak için:

```bash
swift run DynamicIslandMac
```

Testler:

```bash
swift test
```

Başka bir Mac'e kopyalanabilen DMG paketini oluşturmak için:

```bash
make dmg
```

Paket `dist/Dynamic-Island-for-macOS-1.0.0.dmg` konumuna yazılır. DMG içindeki uygulama **Applications** kısayoluna sürüklenir. Paket Developer ID ile notarize edilmediğinden başka bir Mac'te ilk açılışta **Sistem Ayarları → Gizlilik ve Güvenlik → Yine de Aç** adımı gerekebilir.

Temiz bir kurulumun ilk çalıştırmasında Dynamic Island; Bildirim, Konum/Wi‑Fi, Bluetooth, Medya Otomasyonu ve Erişilebilirlik izinlerini sırayla isteyen kurulum penceresini gösterir.

Release derlemesi, sistem genelindeki Now Playing verisini okuyabilmek için sabitlenmiş `MediaRemoteMini` BSD bileşenini indirip uygulama paketine ekler. `swift run` ile çalıştırılan geliştirme sürümü bu paketlenmiş köprü bulunmadığında Music/Spotify Apple Events yöntemine geri döner.

İlk Apple Events medya komutunda macOS, Dynamic Island'ın Music veya Spotify'ı denetlemesi için izin isteyebilir. İzin daha sonra **Sistem Ayarları → Gizlilik ve Güvenlik → Otomasyon** bölümünden değiştirilebilir.

Diğer uygulamaların bildirim içeriği macOS'un normal bildirim API'sinde paylaşılmadığı için Dynamic Island ilk çalıştırmada **Erişilebilirlik** izni ister. İzin **Sistem Ayarları → Gizlilik ve Güvenlik → Erişilebilirlik** bölümünden verilebilir; bildirim metni yalnızca cihaz üzerinde işlenir. Ayarlar'daki **Bildirimi adada önizle** düğmesi görünümü izin vermeden test eder. Sistem tarafından banner olarak gösterilmeyen veya Odak tarafından bastırılan bildirimler aynalanamaz; yerel macOS banner'ı ve Bildirim Merkezi geçmişi silinmez.

Düşük Güç Modu ilk kez değiştirildiğinde macOS standart yönetici onayını bir kez gösterir ve yalnızca bu ayarı değiştirebilen dar yetkili yardımcıyı `/Library/PrivilegedHelperTools` konumuna kurar. Sonraki aç/kapat işlemleri yeniden parola istemeden çalışır. Yardımcı kaldırılırsa veya macOS tarafından devre dışı bırakılırsa ilk kurulum onayı yeniden gerekir; onay iptal edilirse mevcut güç ayarı değiştirilmez.

Uygulamayı kaldırırken güç yardımcısını da silmek isterseniz önce `sudo launchctl bootout system/dev.c0denail.DynamicIslandMac.PowerHelper`, ardından ilgili dosyalar için `sudo rm /Library/LaunchDaemons/dev.c0denail.DynamicIslandMac.PowerHelper.plist /Library/PrivilegedHelperTools/dev.c0denail.DynamicIslandMac.PowerHelper` komutlarını çalıştırın.

Apple'ın Clock uygulaması üçüncü taraflara timer oluşturma/başlatma API'si veya AppleScript sözlüğü sunmadığı için ada, Clock içinde başlatılan timer'ı canlı izler ve **Saat'te Aç** eylemiyle doğrudan Timer ekranına götürür. Ada içinden başlatılan bağımsız odak ve geri sayım sayaçları da çalışmaya devam eder.

Oturum açılışında çalıştır seçeneği için uygulamayı önce `dist` klasöründen `/Applications` klasörüne taşımanız önerilir.

## Mimari

- `IslandPanelCoordinator`: Çentiğe hizalanan şeffaf, tüm Spaces üzerinde görünen `NSPanel`.
- `IslandController`: Sunum durumu, hover davranışı, klavye kısayolu ve etkinlik önceliği.
- `MediaService`: Sistem Now Playing verisi, Chrome/YouTube dahil genel medya denetimi ve Music/Spotify Apple Events yedeği.
- `TimerService`: Hassas geri sayım, kronometre ve bildirimler.
- `ClockTimerService`: macOS Clock timer verisinin salt-okunur canlı senkronu.
- `SystemStatusService`: IOKit pil, Network ağ, CoreAudio ses, yerleşik ekran parlaklığı ve tek sefer yetkilendirilen XPC yardımcısıyla Düşük Güç Modu yönetimi.
- `ConnectivityService`: CoreWLAN Wi‑Fi tarama/bağlanma ve IOBluetooth aygıt/güç yönetimi.
- `NotificationMirrorService`: Bildirim Merkezi banner'larını erişilebilirlik ağacından algılama, içerik çıkarma ve gerçek bildirime yönlendirme.
- `Views`: Mini, kompakt ve geniş SwiftUI arayüzleri.

> Not: Apple, üçüncü taraf uygulamalara sistem genelindeki Now Playing oturumunu okumak ve denetlemek için kararlı, herkese açık bir macOS API'si sunmuyor. Chrome/YouTube entegrasyonu bu nedenle Apple'ın özel `MediaRemote` çerçevesini kullanır; gelecekteki bir macOS güncellemesi köprünün yeniden uyarlanmasını gerektirebilir. Paketlenen BSD bileşeninin lisansı uygulamanın `Contents/Resources/NowPlaying/LICENSE.txt` dosyasındadır.
