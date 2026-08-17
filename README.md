# Dynamic Island for macOS

MacBook çentiğiyle fiziksel olarak hizalanan, SwiftUI ile yazılmış yerel bir macOS Dynamic Island uygulaması.

## Özellikler

- Gerçek çentik geometrisini `NSScreen.auxiliaryTopLeftArea` ve `auxiliaryTopRightArea` ile algılar; boşta tamamen fiziksel çentiğin arkasına gizlenir.
- Chrome/YouTube, Safari, Arc, Music ve Spotify dahil macOS “Şu An Çalıyor” oturumundaki medyanın gerçek kapağını, geçen/kalan süresini ve canlı ilerleme çizgisini gösterir.
- Sistem genelinde oynat/duraklat, önceki/sonraki parça, ±15 saniye sarma ve ilerleme çizgisinden konum değiştirme denetimleri sunar.
- Mac kilitlendiğinde saatin altında Alcove tarzı saydam cam medya kartı gösterir; kapak, başlık, canlı geçen/kalan süre, sürüklenebilir ilerleme çizgisi ve medya denetimleri kilit açılmadan kullanılabilir. Kart parola alanını veya macOS kilit güvenliğini değiştirmez ve Ayarlar’dan kapatılabilir.
- Medya etkinken adanın herhangi bir noktasına tıklamak doğrudan Medya görünümünü, boşta tıklamak genel menüyü açar; fiziksel çentiğin merkezi dahil tüm ada yüzeyi anında tepki verir ve ada dışına tıklamak geniş görünümü kapatır.
- Açılma, küçülme, maskot, waveform ve canlı ilerleme animasyonları VSync ile ekranın doğal yenileme hızında, desteklenen ProMotion ekranlarda 120 FPS çalışır; 60 Hz ekranlarda doğal olarak 60 FPS gösterilir.
- macOS bildirim banner'larını uygulama simgesi, başlık ve içerikle Dynamic Island'da gösterir; art arda gelen bildirimleri sıraya alır ve adaya tıklanınca gerçek bildirim eylemini veya kaynak uygulamayı açar.
- Geri sayım ve kronometreyi doğrudan macOS Saat uygulamasında başlatır, duraklatır, sürdürür ve sıfırlar.
- macOS Saat içinde veya Dynamic Island’dan başlatılan sayaç ve kronometreleri `mobiletimerd` durumundan canlı gösterir; Clock tek doğruluk kaynağıdır.
- CoreAudio ile klavye, AirPods ve Denetim Merkezi ses değişikliklerini; solda ses değeri, sağda düz beyaz seviye çubuğu olacak biçimde yatay Dynamic Island HUD'u olarak gösterir.
- Yerleşik ekranın klavye veya Denetim Merkezi üzerinden değişen parlaklığını aynı yatay düzende; solda güneş simgesi/yüzde, sağda düz beyaz seviye çubuğuyla gösterir.
- Mac güç adaptörüne takıldığında veya çıkarıldığında pil yüzdesi ve varsa tahmini dolum süresiyle şarj animasyonu gösterir.
- AirPods, AirPods Pro, AirPods Max ve diğer Bluetooth kulaklıkları ayrı simgelerle algılar; bağlantı animasyonu ve macOS’un güvenilir biçimde sunduğu kulaklık pil seviyelerini gösterir.
- USB, Thunderbolt ve SD kart depolama aygıtları takıldığında veya çıkarıldığında aygıt adı, türü, kapasitesi ve kullanım çubuğuyla bağlantı animasyonu gösterir; dahili, ağ ve disk image birimlerini filtreler.
- Sistem görünümündeki Wi‑Fi ve Bluetooth kartları açılır bağlantı panelleridir: radyoları açıp kapatır, yakındaki Wi‑Fi ağlarını ve eşleşmiş Bluetooth aygıtlarını listeler, bağlantı kurar veya keser.
- Özet görünümündeki Wi‑Fi durumuna tıklamak doğrudan Sistem bölümündeki Wi‑Fi bağlantı panelini açar.
- Özet görünümünde yaklaşan etkinliği gösteren Takvim kartı bulunur; karta tıklanınca aylık takvim ve yaklaşan etkinlikler Wi‑Fi paneli gibi genişler.
- Ayarlar’daki Kişiselleştirme bölümünden HUD/ilerleme çubuklarının ve uygulama yazılarının renkleri değiştirilebilir.
- Codex’in sıcak piksel-maskot hissinden esinlenen fakat tamamen özgün Byte, Ember, Nova, Moss ve Patch arasından seçim yapılabilir. Maskotların gerçek opak ayak noktası adaya sabitlenir; sol, alt ve sağ kenarlarda uzun süre yürüdükten sonra aniden yuvarlanır, belirgin bir ip sarkıtıp sallanır ve aralarda kendi küçük hareketlerini yapar. Maskot, hız ve aç/kapat seçeneği Ayarlar’dan değiştirilebilir.
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

Paket `dist/Dynamic-Island-for-macOS-v1.1.0.dmg` konumuna yazılır. DMG içindeki uygulama **Applications** kısayoluna sürüklenir. Paket Developer ID ile notarize edilmediğinden başka bir Mac'te ilk açılışta **Sistem Ayarları → Gizlilik ve Güvenlik → Yine de Aç** adımı gerekebilir. Paketleme betiği `CODE_SIGN_IDENTITY` verilmişse onu, aksi halde bu Mac'teki Apple Development kimliğini kullanır; kimlik bulunamazsa ad-hoc imzaya geri döner. Kararlı bir imza, Erişilebilirlik izninin güncellemelerde aynı uygulamayla eşleşmesini sağlar.

Temiz bir kurulumun ilk çalıştırmasında Dynamic Island; Bildirim, Konum/Wi‑Fi, Bluetooth, Takvim, Medya Otomasyonu ve Erişilebilirlik izinlerini sırayla isteyen kurulum penceresini gösterir.

Release derlemesi, sistem genelindeki Now Playing verisini okuyabilmek için sabitlenmiş `MediaRemoteMini` BSD bileşenini indirip uygulama paketine ekler. `swift run` ile çalıştırılan geliştirme sürümü bu paketlenmiş köprü bulunmadığında Music/Spotify Apple Events yöntemine geri döner.

İlk Apple Events medya komutunda macOS, Dynamic Island'ın Music veya Spotify'ı denetlemesi için izin isteyebilir. İzin daha sonra **Sistem Ayarları → Gizlilik ve Güvenlik → Otomasyon** bölümünden değiştirilebilir.

Kilit ekranı medya kartı yalnızca uygulamanın çalıştığı, giriş yapılmış mevcut kullanıcı oturumu kilitlendiğinde gösterilir. Yeniden başlatma sonrası FileVault/preboot veya oturum açılmadan önceki giriş ekranında kullanıcı uygulamaları çalışmadığı için gösterilemez. Hızlı Kullanıcı Değiştirme sırasında önceki kullanıcının medya bilgisi başka oturuma taşınmaz. macOS, üçüncü taraf uygulamalar için kilit ekranına özel pencere yerleştirme API'si sunmadığından kart, çalışma anında doğrulanan özel SkyLight sembolleriyle ayrı kilit alanına taşınır; semboller bulunamazsa parola arayüzünü örtme riski almamak için kart kapalı kalır. Bu deneysel entegrasyon gelecekteki macOS güncellemelerinde yeniden uyarlama gerektirebilir. İlgili MIT atfı uygulama paketindeki `Contents/Resources/Licenses/SkyLightWindow-LICENSE.txt` dosyasındadır.

Diğer uygulamaların bildirim içeriği macOS'un normal bildirim API'sinde paylaşılmadığı için Dynamic Island ilk çalıştırmada **Erişilebilirlik** izni ister. İzin **Sistem Ayarları → Gizlilik ve Güvenlik → Erişilebilirlik** bölümünden verilebilir; bildirim metni yalnızca cihaz üzerinde işlenir. Önceki ad-hoc imzalı bir sürümden geçerken anahtar açık görünmesine rağmen izin eşleşmiyorsa eski Dynamic Island satırını `−` ile kaldırıp `/Applications/Dynamic Island.app` dosyasını `+` ile yeniden ekleyin ve uygulamayı kapatıp açın. Ayarlar'daki **Bildirimi adada önizle** düğmesi görünümü izin vermeden test eder. Sistem tarafından banner olarak gösterilmeyen veya Odak tarafından bastırılan bildirimler aynalanamaz; yerel macOS banner'ı ve Bildirim Merkezi geçmişi silinmez.

Düşük Güç Modu ilk kez değiştirildiğinde macOS standart yönetici onayını bir kez gösterir ve yalnızca bu ayarı değiştirebilen dar yetkili yardımcıyı `/Library/PrivilegedHelperTools` konumuna kurar. Sonraki aç/kapat işlemleri yeniden parola istemeden çalışır. Yardımcı kaldırılırsa veya macOS tarafından devre dışı bırakılırsa ilk kurulum onayı yeniden gerekir; onay iptal edilirse mevcut güç ayarı değiştirilmez.

Uygulamayı kaldırırken güç yardımcısını da silmek isterseniz önce `sudo launchctl bootout system/dev.c0denail.DynamicIslandMac.PowerHelper`, ardından ilgili dosyalar için `sudo rm /Library/LaunchDaemons/dev.c0denail.DynamicIslandMac.PowerHelper.plist /Library/PrivilegedHelperTools/dev.c0denail.DynamicIslandMac.PowerHelper` komutlarını çalıştırın.

Apple'ın Clock uygulaması timer/kronometre yönetimi için herkese açık bir macOS API'si veya AppleScript sözlüğü sunmadığından uygulama, mevcut Erişilebilirlik izniyle Clock’un kararlı kontrol kimliklerini kullanır. Her komutta Clock penceresi öne getirilmeden erişilebilirlik için hazırlanır, hedef sekme yeniden seçilir ve gerçek Clock durumu değişene kadar sonuç doğrulanır. Clock durum dosyaları yalnızca okunur; veritabanına veya tercih dosyasına yazılmaz. Arayüz kimlikleri gelecekteki büyük bir macOS güncellemesinde değişirse köprünün uyarlanması gerekebilir.

Oturum açılışında çalıştır seçeneği için uygulamayı önce `dist` klasöründen `/Applications` klasörüne taşımanız önerilir.

## Mimari

- `IslandPanelCoordinator`: Çentiğe hizalanan şeffaf, tüm Spaces üzerinde görünen `NSPanel`.
- `LockScreenMediaCoordinator`: Gerçek oturum kilidini doğrulayan, sınırlı medya panelini özel kilit alanına taşıyan ve kullanıcı değişiminde veriyi anında gizleyen koordinatör.
- `LockScreenSpaceBridge`: Gerekli özel SkyLight sembollerini çalışma anında güvenli biçimde çözen, desteklenmeyen sistemlerde kapalı kalan kilit alanı köprüsü.
- `IslandController`: Sunum durumu, hover davranışı, klavye kısayolu ve etkinlik önceliği.
- `MediaService`: Sistem Now Playing verisi, Chrome/YouTube dahil genel medya denetimi ve Music/Spotify Apple Events yedeği.
- `TimerService`: Sayaç/kronometre türü ve seçili geri sayım süresi.
- `ClockTimerService`: macOS Clock timer/kronometre durumunun salt-okunur canlı senkronu ve Erişilebilirlik tabanlı Clock komut köprüsü.
- `SystemStatusService`: IOKit pil, Network ağ, CoreAudio ses, yerleşik ekran parlaklığı ve tek sefer yetkilendirilen XPC yardımcısıyla Düşük Güç Modu yönetimi.
- `ConnectivityService`: CoreWLAN Wi‑Fi tarama/bağlanma ve IOBluetooth aygıt/güç yönetimi.
- `ChargingEventService`: IOKit güç kaynağı değişikliklerinden şarj takma/çıkarma olayları ve pil bilgileri.
- `AudioAccessoryService`: CoreAudio, IOBluetooth ve standart HID verileriyle kulaklık türü, bağlantısı ve mevcut pil bilgileri.
- `ExternalStorageService`: NSWorkspace ve Disk Arbitration ile fiziksel harici depolama takma/çıkarma olayları.
- `NotificationMirrorService`: Bildirim Merkezi banner'larını erişilebilirlik ağacından algılama, içerik çıkarma ve gerçek bildirime yönlendirme.
- `Views`: Mini, kompakt ve geniş SwiftUI arayüzleri.

> Not: Apple, üçüncü taraf uygulamalara sistem genelindeki Now Playing oturumunu okumak ve denetlemek için kararlı, herkese açık bir macOS API'si sunmuyor. Chrome/YouTube entegrasyonu bu nedenle Apple'ın özel `MediaRemote` çerçevesini kullanır; gelecekteki bir macOS güncellemesi köprünün yeniden uyarlanmasını gerektirebilir. Paketlenen BSD bileşeninin lisansı uygulamanın `Contents/Resources/NowPlaying/LICENSE.txt` dosyasındadır.
