# Coverrrup 배포 파일

이 폴더의 파일을 전부 GitHub 저장소에 올리고, Cloudflare Pages로 연결하면 끝입니다.

- index.html    앱 전체 (Supabase 주소와 Publishable key가 들어 있음)
- manifest.json 홈 화면에 추가할 때 쓰는 앱 정보
- icon-192.png, icon-512.png  앱 아이콘
- _headers      카메라/위치 권한 헤더

## 배포 후 Supabase에서 해야 하는 것 (한 번만)
Supabase → Authentication → URL Configuration
- Site URL:        https://coverrrup.pages.dev   (나중에 https://coverrrup.com 으로 변경)
- Redirect URLs:   https://coverrrup.pages.dev/**  와  https://coverrrup.com/**  둘 다 추가

## 지도
바탕 지도는 OpenFreeMap(무료, 키 없음)을 씁니다. 나중에 구글맵으로 바꾸려면 index.html 위쪽 MAP_STYLE 한 줄만 바꾸면 됩니다.
