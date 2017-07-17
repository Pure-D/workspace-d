rem Building & compressing workspace-d for release inside a virtual machine with Windows 8 or above
rem This will delete the folder C:\build

del /S /Q C:\build
xcopy /e . C:\build
pushd C:\build
dub build --build=release --compiler=ldc2 --combined
echo Y | del windows
mkdir windows
echo F | xcopy /f workspace-d.exe windows\workspace-d.exe
echo F | xcopy /f libcurl.dll windows\libcurl.dll
echo F | xcopy /f libeay32.dll windows\libeay32.dll
echo F | xcopy /f ssleay32.dll windows\ssleay32.dll
del C:\build\windows.zip
powershell -nologo -noprofile -command "& { Add-Type -A 'System.IO.Compression.FileSystem'; [IO.Compression.ZipFile]::CreateFromDirectory('windows', 'windows.zip'); }"
popd
echo F | xcopy C:\build\windows.zip workspace-d-2.x.x-windows.zip
