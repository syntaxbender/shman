# fwknop Script Workflow (Prepare / Exchange / Finalize)

Bu dizindeki scriptler:

- `fwknop_server_prepare.sh`
- `fwknop_client_exchange.sh`
- `fwknop_server_finalize.sh`

amacıyla birlikte tek bir uçtan uca kurulum akışı oluşturur:

1. Server hazırlığı
2. Client anahtar/değer alışverişi
3. Server finalize

## 1) Gereksinimler

## İşletim sistemi ve araçlar

- Ubuntu/Debian tabanlı bir sistem (scriptler `apt` kullanır)
- `bash`
- Server ve client arasında SSH/SCP erişimi

## Yetki modeli

- `fwknop_server_prepare.sh`: Server'da `root` yetkisi ile çalıştırılmalı
- `fwknop_server_finalize.sh`: Server'da `root` yetkisi ile çalıştırılmalı
- `fwknop_client_exchange.sh`: Client'ta normal kullanıcı ile çalıştırılır, ancak paket kurulumu için `sudo` ister

## GPG modeli

- Server private key doğrudan `root` keyring altında üretilir: `/root/.gnupg`
- Key expiry yok (`sign 0`), yani süresiz anahtar
- Import sonrası karşılıklı `sign` + `ownertrust` (`2 = I do NOT trust`) uygulanır

## Firewall ön koşulu

Scriptler firewall'ı sıfırdan kurmaz. Finalize adımı çalışmadan önce server'da en az şu durumlar hazır olmalı:

- `INPUT` policy: `DROP`
- `ESTABLISHED,RELATED` kabul kuralı mevcut
- `SPA_PORT` için UDP `ACCEPT` kuralı mevcut
- SSH portu için kaldırılacak bir `ACCEPT` kuralı mevcut (finalize bu kuralı bulup kaldırır)

## 2) Scriptlerin Nerede Duracağı

Scriptleri iki tarafta da bir klasörde tut:

- Server: örn. `~/fwknop/`
- Client: örn. `~/fwknop/`

Bu dokümandaki komutlar bu dizinden çalıştırılacak şekilde yazılmıştır.

## 3) Çalıştırma Sırası (Zorunlu Akış)

## Adım A - Server Prepare (server tarafı)

Server'da:

```bash
cd ~/fwknop
chmod +x ./*.sh
sudo ./fwknop_server_prepare.sh
```

Scriptin yaptığı ana işler:

- `fwknop-server`, `gnupg`, `iptables-persistent` vb. paketleri kurar
- UFW'yi kapatır
- Server GPG secret key'i `root` keyring altında üretir
- Server public key ve HMAC key dosyalarını `SERVER_USER` home altına yazar:
  - `fwknop-<PROFILE>-server-pub.asc`
  - `fwknop-<PROFILE>-hmac.key`
- `/etc/fwknop/fwknopd.conf` dosyasını oluşturur

## Adım B - Client Exchange (client tarafı)

Client'ta:

```bash
cd ~/fwknop
chmod +x ./*.sh
./fwknop_client_exchange.sh
```

Scriptin yaptığı ana işler:

- Server kullanıcısının home dizinini SSH ile dinamik olarak bulur
- Server'dan server public key ve HMAC key'i çeker
- Client GPG secret key üretir (expiry yok)
- Server public key'i import + sign + ownertrust eder
- Client public key'i server'a yollar
- `~/.fwknoprc` içine profile bloğunu ekler

## Adım C - Server Finalize (server tarafı)

Server'da:

```bash
cd ~/fwknop
sudo ./fwknop_server_finalize.sh
```

Scriptin yaptığı ana işler:

- `root` keyring'de server secret key varlığını doğrular
- Client public key'i import + sign + ownertrust eder
- `/etc/fwknop/access.conf` dosyasını yazar
- `fwknop-server` servisini enable/restart eder
- iptables ön koşullarını kontrol eder
- SSH `ACCEPT` kuralını kullanıcı onayı ile kaldırır
- iptables kurallarını kalıcılaştırır (`/etc/iptables/rules.v4`)

## 4) Dosya ve Konum Özeti

## Server tarafı

- Scriptler: `~/fwknop/*.sh`
- Root keyring: `/root/.gnupg`
- Üretilen dosyalar (`SERVER_USER` home):
  - `fwknop-<PROFILE>-server-pub.asc`
  - `fwknop-<PROFILE>-hmac.key`
  - `fwknop-<PROFILE>-client-pub.asc` (exchange sonrası)
- Konfig dosyaları:
  - `/etc/fwknop/fwknopd.conf`
  - `/etc/fwknop/access.conf`

## Client tarafı

- Scriptler: `~/fwknop/*.sh`
- GPG home: `~/.gnupg`
- fwknop client profil dosyası: `~/.fwknoprc`

## 5) Hangi Script Hangi Yetkiyle?

- `sudo ./fwknop_server_prepare.sh` (server)
- `./fwknop_client_exchange.sh` (client, kullanıcı + gerektiğinde sudo)
- `sudo ./fwknop_server_finalize.sh` (server)

## 6) Tekrar Çalıştırma ve İdempotency Notları

Scriptler korumalı davranır; aynı profile ile ikinci çalıştırmada hata vermesi normaldir.

- Prepare: aynı profile için server secret key veya output dosyaları varsa durur
- Exchange: `~/.fwknoprc` içinde profile varsa veya client secret key varsa durur
- Finalize: client public key root keyring'de zaten varsa durur

Aynı profile'i tekrar kurmak için eski key/dosya/profil kayıtlarını temizlemen gerekir.

## 7) Hızlı Doğrulama

Client'tan:

```bash
fwknop -n <PROFILE> -vv
ssh -p <SSH_PORT> <SERVER_USER>@<SERVER_HOST>
```

Server'da debug:

```bash
sudo journalctl -u fwknop-server --no-pager
sudo iptables -L INPUT -n -v --line-numbers
```
