# batting-meditation.github.io
## 타격 명상 / 타격 연습장

- `index.html`: 타격 명상 (사이트 첫 화면)
- `practice.html`: 타격 연습장

파일 하나로 도는 3D 타격 웹앱입니다 (Three.js).

### 사용한 외부 자료
- 선수 모델: three.js 예제의 Ready Player Me 아바타(`examples/models/gltf/readyplayer.me.glb`)를 손질해 `assets/player.glb.txt`(base64)로 저장
- 모션 캡처: CMU Graphics Lab Motion Capture Database (http://mocap.cs.cmu.edu), subject 124, trial 1·2(투구 3개)·7(스윙 2개). 관절 위치와 관절 회전값(쿼터니언)으로 변환해 `assets/mocap.json`에 저장
- 타자 동작: 직접 녹화한 플레이 참고 영상에서 포즈 추정(MediaPipe Pose)으로 관절 위치를 뽑고, 화면 속 홈플레이트·타석 선으로 카메라를 역산해 3차원으로 복원한 값 (`assets/game_batter.json`). 게임의 그래픽·모델·음원 등 에셋은 포함하지 않음

## 타격 명상 (index.html)

직구만 스트라이크 존으로 계속 날아오고, 화면에는 지금까지 날려 보낸 거리의 합계만 표시됩니다. 합계는 이 기기의 브라우저에만 저장됩니다. `index.html`은 `practice.html`에서 `tools/build-zen.sh`로 생성하므로, `practice.html`을 고친 뒤에는 스크립트를 다시 실행하세요. (`practice.html?zen` 으로도 같은 모드가 열립니다.)

### 순위표 (선택)

타격 명상은 Supabase(무료)에 **주간 누적 거리 순위**(한국 시간 월요일 0시에 새로 시작)와 **명예의 전당**(지난 주마다 1위)을 둡니다. Supabase 프로젝트의 SQL Editor에서 `tools/supabase-weekly.sql`을 실행한 뒤, `assets/leaderboard.json`에 `{"url": "https://<프로젝트>.supabase.co", "key": "<anon 또는 publishable 키>"}`를 넣으면 시작 화면에 순위표가 나타납니다. service_role/secret 키는 절대 넣지 마세요.

닉네임과 비밀번호(숫자 4~6자리)를 정하면 어느 브라우저·폰에서든 같은 기록으로 이어서 할 수 있습니다. 카카오톡·인스타그램 같은 앱 안 브라우저로 열면 기본 브라우저로 넘기거나 여는 방법을 안내합니다.
