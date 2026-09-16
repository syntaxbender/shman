# shman
Easy cli shared hosting manager on ubuntu/debian derivates

## SSH hardening

`ssh_setup.sh`, `ubuntu` kullanıcısının mevcut `authorized_keys` kayıtlarını
parmak izi ve yorumlarıyla doğrulatır; seçilen portta yalnız public-key SSH
erişimini etkinleştirir ve root/parola/keyboard-interactive girişlerini kapatır.
Yönetilen dosyada bulunan direktifleri günceller, eksik direktifleri sona ekler
ve yeni seçilen portun başka bir servis tarafından kullanılmadığını kontrol eder.

```bash
sudo ./ssh_setup.sh
```

Script, yeni yapılandırmayı `sshd -t` ile doğruladıktan sonra SSH servisini
yeniden yükler. Firewall kuralları ayrıca yönetilir; `iptables_setup.sh`
çalıştırılırken aynı SSH portu seçilmelidir. Aktif bir WAN firewall varsa yeni
port önce firewall'da açılmalı ve mevcut oturum yeni bağlantı denenene kadar
kapatılmamalıdır.
