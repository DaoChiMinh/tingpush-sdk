# Phát hành SDK

Thư mục `sdk/` là nội dung của repo public **https://github.com/tingpush/tingpush-sdk** (giấy phép MIT).
Đổi tên repo thì tìm-thay `tingpush/tingpush-sdk` trong `sdk/` (Package.swift, pubspec.yaml, package.json, TingPush.Maui.csproj, README).

| SDK | Kho | Dev cài bằng |
|---|---|---|
| iOS | Swift Package Manager (repo GitHub + tag) | Xcode → *Add Package Dependencies…* → `https://github.com/tingpush/tingpush-sdk` |
| Android | JitPack (build từ tag GitHub) | `implementation("com.github.tingpush.tingpush-sdk:tingpush:1.0.0")` |
| Flutter | pub.dev | `flutter pub add tingpush` |
| React Native | npm | `npm install @tingpush/react-native` |
| .NET MAUI | nuget.org | `dotnet add package TingPush.Maui` |

## 0. Đẩy `sdk/` lên repo public và gắn tag

Chạy ở gốc repo nội bộ (lần sau chạy lại y hệt, git chỉ thêm commit mới):

```bash
git subtree split --prefix=sdk -b sdk-public
git push https://github.com/tingpush/tingpush-sdk.git sdk-public:main
git tag 1.0.0 sdk-public
git push https://github.com/tingpush/tingpush-sdk.git 1.0.0
```

Tag dạng `1.0.0` (không có chữ `v`) — SPM và JitPack đọc phiên bản từ tag này.

## 1. iOS (SPM)

Không cần upload: có tag là dev thêm được package bằng URL repo. `Package.swift` ở gốc repo trỏ tới `ios/Sources/TingPush`.

CocoaPods: trunk chuyển chỉ-đọc từ 12/2026 nên không đẩy lên trunk. `ios/TingPush.podspec` vẫn dùng được theo kiểu `pod 'TingPush', :git => 'https://github.com/tingpush/tingpush-sdk.git', :tag => '1.0.0'` nếu sửa `s.source` và đường dẫn `source_files` cho khớp gốc repo.

## 2. Android (JitPack)

1. Vào https://jitpack.io, nhập `tingpush/tingpush-sdk`, bấm **Get it** ở tag `1.0.0` để JitPack build (theo `jitpack.yml`: `./gradlew :tingpush:publishToMavenLocal`).
2. Dev khai báo:

```kotlin
// settings.gradle.kts
dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
        maven("https://jitpack.io")
    }
}

// app/build.gradle.kts
dependencies {
    implementation("com.github.tingpush.tingpush-sdk:tingpush:1.0.0")
}
```

Chạy thử như JitPack trên máy: `./gradlew :tingpush:publishToMavenLocal` ở thư mục `sdk/` (cần `ANDROID_HOME`).
Sau khi sở hữu tên miền tingpush.com có thể chuyển sang Maven Central với groupId `com.tingpush`.

## 3. Flutter (pub.dev)

```bash
cd flutter/tingpush
dart pub publish --dry-run   # kiểm tra
dart pub login               # tài khoản Google
dart pub publish
```

Nên tạo *verified publisher* `tingpush.com` trên pub.dev (cần xác minh tên miền) rồi chuyển package sang publisher đó.

## 4. React Native (npm)

Tạo org `tingpush` trên npmjs.com (miễn phí cho gói public), rồi:

```bash
cd react-native/tingpush
npm install          # cài typescript để build lib/
npm login
npm publish          # prepack tự chạy tsc; publishConfig.access = public
```

## 5. .NET MAUI (NuGet)

Cần máy có workload `android` và `ios`.

```bash
cd maui/TingPush.Maui
dotnet pack -c Release -o out
dotnet nuget push out/TingPush.Maui.1.0.0.nupkg --api-key <NUGET_API_KEY> --source https://api.nuget.org/v3/index.json
```

## Khi ra phiên bản mới

Tăng version ở các file sau cho đồng bộ, rồi lặp lại các bước trên với tag mới:

- `flutter/tingpush/pubspec.yaml` + `flutter/tingpush/CHANGELOG.md`
- `react-native/tingpush/package.json`
- `maui/TingPush.Maui/TingPush.Maui.csproj` (`<Version>`)
- `android/tingpush/build.gradle.kts` (`version` trong `publishing`)
- `ios/TingPush.podspec` (`s.version`)
