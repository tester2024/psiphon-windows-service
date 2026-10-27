# سرویس ویندوزی Psiphon

[English](README.md) | فارسی

این پروژه `psiphon-tunnel-core` را به‌صورت یک سرویس ویندوز اجرا می‌کند. تونل در پس‌زمینه کار می‌کند، با روشن شدن سیستم بالا می‌آید و پروکسی `SOCKS5` محلی را روی `127.0.0.1:9999` در اختیار برنامه‌ها می‌گذارد.

خود tunnel-core یک برنامه‌ی کنسولی است و رابط سرویس ویندوز را پیاده‌سازی نمی‌کند. فایل `psiphon-service.exe` این بخش را انجام می‌دهد: تونل را اجرا می‌کند، اگر بسته شد دوباره بالا می‌آوردش، با تغییر فایل تنظیمات آن را دوباره بارگذاری می‌کند و وقتی ویندوز سرویس را متوقف می‌کند، آن را تمیز می‌بندد.

## چه چیزی نصب می‌شود

- سرویس `PsiphonTunnelCore` با شروع خودکار، پیش از ورود کاربر و با حساب `LocalSystem`.
- پروکسی `SOCKS5` روی `127.0.0.1:9999`. پروکسی HTTP هم وجود دارد، ولی پیش‌فرض خاموش است.
- دستور `psiphon` برای دیدن وضعیت، انتخاب کشور، تست سرعت و خواندن لاگ‌ها.
- بارگذاری خودکار تنظیمات. هر وقت `config\psiphon.config` را تغییر دهید، سرویس در چند ثانیه تونل را دوباره راه می‌اندازد.

## نصب

فایل `psiphon-windows-service-<version>.zip` را از صفحه‌ی Releases بگیرید، هر جایی که خواستید باز کنید (مثلاً `C:\Tools\psiphon`) و این دستور را اجرا کنید:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\install.ps1
```

اسکریپت خودش درخواست دسترسی مدیر می‌کند، فایل‌های تنظیمات را برای همان مسیر می‌سازد، سرویس را ثبت می‌کند و پوشه‌ی `cli` را به `PATH` کاربر اضافه می‌کند. بعد از آن یک ترمینال تازه باز کنید و بنویسید:

```powershell
psiphon status
```

پروکسی بلافاصله شروع به گوش دادن می‌کند، اما گرفتن لیست سرورها و برقراری اتصال ۲۰ تا ۶۰ ثانیه طول می‌کشد. تا وقتی `psiphon status` یک منطقه نشان نداده، درخواست‌ها از پروکسی خطا می‌دهند.

### استفاده از پروکسی

تنظیماتی که باید در برنامه‌تان وارد کنید:

- نوع پروکسی: `SOCKS5` یا `SOCKS5h` (با DNS از راه دور).
- نشانی: `127.0.0.1`
- پورت: `9999`
- احراز هویت: ندارد.

```powershell
curl.exe -x socks5h://127.0.0.1:9999 https://api.ipify.org
```

پروکسی فقط روی `localhost` گوش می‌دهد. اگر می‌خواهید دستگاه‌های دیگر شبکه هم از آن استفاده کنند، در فایل تنظیمات مقدار `ListenInterface` را روی `any` بگذارید و پورت `9999` را در فایروال ویندوز باز کنید. این کار را فقط در شبکه‌ای انجام دهید که به آن اعتماد دارید.

## دستورها

- برای دیدن وضعیت سرویس، پورت‌ها و منطقه‌ی اتصال: `psiphon status`
- برای اتصال از یک کشور مشخص، مثلاً آلمان: `psiphon set-country de`. با `psiphon set-country auto` بهترین سرور انتخاب می‌شود.
- برای دیدن کشورهایی که شبکه الان ارائه می‌دهد: `psiphon regions`
- برای دیدن یا عوض کردن پورت `SOCKS5`: `psiphon socks 9999`
- برای روشن یا خاموش کردن پروکسی HTTP: `psiphon http off` یا `psiphon http 8080`
- برای اندازه‌گیری آی‌پی خروجی، تاخیر و جیتر، و سرعت دانلود و آپلود: `psiphon test`
- برای اجرای نصف تست: `psiphon ping` یا `psiphon speed`
- برای دیدن ۵۰ خط آخر لاگ تونل: `psiphon logs 50`
- برای کنترل سرویس: `psiphon start`، `psiphon stop` و `psiphon restart`. این‌ها دسترسی مدیر می‌خواهند.

خروجی `psiphon test` چیزی شبیه این است:

```
  Psiphon speed test
  ----------------------------------------------------------------
  exit IP    172.232.154.35    SE  |  Stockholm  |  AS63949 Akamai Connected Cloud
  socks5 127.0.0.1:9999  |  server SE  |  QUIC-OSSH
  ----------------------------------------------------------------

  ----------------------------------------------------------------
  latency     121 ms avg   min 112  |  max 129  |  jitter 8 ms  (5 samples)
  download   0.67 Mbps avg peak 1.23  |  2.0 MB in 25.2 s
  upload     1.82 Mbps avg  |  1.0 MB in 4.3 s
  ----------------------------------------------------------------
```

تست پیش‌فرض ۵ پینگ، ۲ مگابایت دانلود و ۱ مگابایت آپلود دارد و حدود ۱۵ ثانیه طول می‌کشد. با `psiphon test quick` حجم‌ها کمتر می‌شود و `psiphon test 10` یک دانلود ۱۰ مگابایتی می‌گیرد. نتیجه‌ی هر تست به `logs\speedtest.log` اضافه می‌شود.

## تنظیمات

فایل `config\psiphon.config` یک تنظیمات معمولی tunnel-core است. مقادیر لازم برای پیدا کردن سرورها (نشانی لیست سرور و کلیدهای امضا) از کلاینت عمومی Psiphon گرفته شده‌اند؛ به همین دلیل به حساب کاربری یا توکن نیازی نیست.

کلیدهایی که بیشتر به کار می‌آیند:

```jsonc
"LocalSocksProxyPort": 9999,
"DisableLocalSocksProxy": false,
"LocalHttpProxyPort": 0,
"DisableLocalHttpProxy": true,
"EgressRegion": "DE",      // omit for the best server in any country
"ListenInterface": ""      // "" = localhost, "any" = all interfaces
```

`EgressRegion` را روی کد دوحرفی کشور بگذارید یا حذفش کنید تا بهترین سرور انتخاب شود. `ListenInterface` خالی یعنی فقط `localhost` و مقدار `any` یعنی همه‌ی واسط‌های شبکه.

بعد از ذخیره‌ی فایل، سرویس در حدود دو ثانیه تونل را دوباره بالا می‌آورد. دستورهای `psiphon set-country` و `psiphon socks` هم همین فایل را ویرایش می‌کنند.

## محدودیت‌ها

- UDP پشتیبانی نمی‌شود. پروکسی محلی فقط `CONNECT` در `SOCKS5` را پیاده‌سازی کرده است و `UDP ASSOCIATE` و رله‌ی UDP ندارد. برنامه‌هایی که UDP لازم دارند، مثل WireGuard، تماس صوتی بازی‌ها و کلاینت‌هایی که فقط با QUIC کار می‌کنند، از آن عبور نمی‌کنند.
- فقط ویندوز. میزبان سرویس مخصوص ویندوز است و پشتیبانی تونل TUN در psiphon-tunnel-core برای ویندوز پیاده‌سازی نشده است.
- بعد از روشن شدن سیستم چند ثانیه طول می‌کشد تا تونل بتواند ترافیک را رد کند.
- اگر پروکسی سراسری یا فایروالی روی سیستم باشد که اتصال به سرورهای Psiphon را ببندد، کلاینت مدام تلاش می‌کند ولی ممکن است وصل نشود.

## فایل‌ها

```
bin\psiphon-tunnel-core.exe   tunnel core, built from source
bin\psiphon-service.exe       service host
cli\psiphon.ps1               command line helper
config\psiphon.config         generated at install time
config\service.json           generated at install time
data\                         tunnel data store
logs\                         service and tunnel logs
scripts\install.ps1           installer
scripts\uninstall.ps1         removes the service
```

لاگ سرویس در ۵ مگابایت و لاگ تونل در ۱۰ مگابایت می‌چرخد.

## حذف

```powershell
powershell -ExecutionPolicy Bypass -File scripts\uninstall.ps1
```

این دستور سرویس و ورودی `PATH` را حذف می‌کند. تنظیمات، داده‌ها و لاگ‌ها سر جایشان می‌مانند؛ اگر لازم نیستند، خود پوشه را پاک کنید.

## ساخت از سورس

به `Go 1.26` یا جدیدتر و `git` نیاز دارید.

```powershell
git clone https://github.com/Psiphon-Labs/psiphon-tunnel-core.git upstream
git -C upstream checkout v2.0.42

# tunnel core
cd upstream
$env:CGO_ENABLED = "0"
$env:GOFLAGS = "-mod=vendor"
go build -trimpath -ldflags "-s -w" -o ..\bin\psiphon-tunnel-core.exe .\ConsoleClient
cd ..

# service host
cd service
$env:GOFLAGS = ""
go build -trimpath -ldflags "-s -w" -o ..\bin\psiphon-service.exe .
```

ورک‌فلو گیت‌هاب همین کار را روی هر push انجام می‌دهد و روی تگ‌ها فایل zip منتشر می‌کند.

## اعتبارها

`psiphon-tunnel-core` ساخته‌ی Psiphon Inc. است و تحت `GPLv3` منتشر شده. میزبان سرویس و اسکریپت‌های این مخزن هم `GPLv3` هستند؛ فایل `LICENSE` را ببینید.
