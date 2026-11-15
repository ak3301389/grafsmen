@echo off
chcp 65001 >nul
cd /d D:\APP\grafik

for /f "tokens=2" %%a in ('findstr /b "version:" pubspec.yaml') do set "full_ver=%%a"

for /f "tokens=1 delims=+" %%a in ("%full_ver%") do set "ver_part=%%a"
for /f "tokens=1-3 delims=." %%a in ("%ver_part%") do (
  set "major=%%a"
  set "minor=%%b"
  set "patch=%%c"
)

for /f "tokens=2 delims=+" %%a in ("%full_ver%") do set "old_build=%%a"
if "%old_build%"=="" set "old_build=0"

echo.
echo Текущая версия: %major%.%minor%.%patch%.%old_build%
echo.
echo Выберите тип:
echo 1 - Исправление (Patch)
echo 2 - Новая функция (Minor)
echo 3 - Крупное изменение (Major)
echo 4 - Просто пересборка (Build)
set /p version_type="Тип (1-4): "

if "%version_type%"=="1" (
  set /a patch=patch+1
  set /a build_num=old_build+1
)
if "%version_type%"=="2" (
  set /a minor=minor+1
  set patch=0
  set /a build_num=old_build+1
)
if "%version_type%"=="3" (
  set /a major=major+1
  set minor=0
  set patch=0
  set /a build_num=old_build+1
)
if "%version_type%"=="4" (
  set /a build_num=old_build+1
)

set /p comment="Комментарий: "

powershell -Command "(Get-Content pubspec.yaml) -replace 'version: .*', 'version: %major%.%minor%.%patch%+%build_num%' | Set-Content pubspec.yaml"

REM =========================================
REM СБОРКА APK
REM =========================================
echo.
echo === Сборка APK ===
call flutter build apk --release

if errorlevel 1 (
  echo ОШИБКА СБОРКИ APK!
  pause
  exit /b 1
)

mkdir release 2>nul

set "apk_name=grafsmen.v%major%.%minor%.%patch%.%build_num%.apk"
copy "build\app\outputs\flutter-apk\app-release.apk" "release\%apk_name%"

echo APK готов: release\%apk_name%

REM =========================================
REM ЗАЛИВКА APK НА GITHUB
REM =========================================
echo.
echo === Заливка APK на GitHub ===

gh release create v%major%.%minor%.%patch%.%build_num% ^
  "release\%apk_name%" ^
  --repo ak3301389/grafsmen ^
  --title "v%major%.%minor%.%patch%.%build_num%" ^
  --notes "%comment%"

if errorlevel 1 (
  echo.
  echo ОШИБКА ЗАЛИВКИ APK НА GITHUB!
  echo APK остался локально: release\%apk_name%
) else (
  echo APK залит: https://github.com/ak3301389/grafsmen/releases/tag/v%major%.%minor%.%patch%.%build_num%
)

echo.
echo =========================================
echo ВСЁ ГОТОВО! Версия: v%major%.%minor%.%patch%.%build_num%
echo APK:  https://github.com/ak3301389/grafsmen/releases/tag/v%major%.%minor%.%patch%.%build_num%
echo =========================================
pause