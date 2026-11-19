param(
  [string[]]$Months = @("202612", "202701"),
  [string]$OutPath = "data/ezwel_rooms.json"
)

$ErrorActionPreference = "Continue"
$utf8 = [Text.Encoding]::UTF8

# 40개 숙소코드
$hotels = [ordered]@{
  "설해원"=12443; "롯데호텔 월드"=11813; "비스타 워커힐 서울"=11945; "오크밸리 리조트"=12156
  "소피텔 앰배서더 서울 호텔"=12155; "블룸비스타호텔앤컨퍼런스"=12173; "네스트호텔"=12168
  "파라다이스 호텔 부산"=12167; "무주 덕유산 리조트"=12514; "체스터톤스 경주 더 테라스 호텔"=12513
  "웨스틴 조선 부산"=12512; "호텔 오노마 대전 오토그래프 컬렉션"=12516; "기린빌라리조트 제주"=12515
  "롯데리조트 부여"=12519; "롯데리조트 속초"=12444; "포레스트 리솜 제천"=12453; "아일랜드 리솜 안면도"=12452
  "스플라스 리솜 덕산"=12451; "레스트리 리솜 제천"=12450; "켄싱턴리조트 서귀포"=12520; "켄싱턴리조트 설악밸리"=12447
  "켄싱턴리조트 경주"=12446; "한화리조트 해운대"=12431; "한화리조트 경주"=12425; "한화리조트 제주"=12429
  "한화리조트 용인 베잔송"=12428; "소노캄 여수"=12439; "소노캄 경주"=12438; "소노벨 천안"=12437
  "소노벨 비발디파크"=12434; "쏠비치 진도"=12433; "쏠비치 삼척"=12432; "소노펠리체 델피노"=12528
  "소노캄 델피노"=12525; "소노벨 제주"=12524; "쏠비치 남해"=12522; "소노캄 거제"=12521
  "소노펠리체 빌리지 델피노"=12527; "소노캄 비발디파크"=12526; "소노벨 변산"=12523
}

$fetchedAt = (Get-Date).ToString("yyyy-MM-ddTHH:mm:sszzz")
$failed = New-Object System.Collections.ArrayList
$rows = New-Object System.Collections.ArrayList

foreach ($h in $hotels.Keys) {
  $code = $hotels[$h]
  foreach ($m in $Months) {
    $url = "https://apim.ezwel.com/lodgement/api/v1/lodge-room/3298/2004/1002/$code/daily-count?clndYm=$m&ldgPksnPlcyNo=1&ldgOrdAplNos=1"
    try {
      $resp = Invoke-WebRequest -UseBasicParsing -Uri $url -TimeoutSec 30
      $json = $utf8.GetString($resp.RawContentStream.ToArray()) | ConvertFrom-Json
      if ($null -eq $json.data) {
        [void]$failed.Add([pscustomobject]@{ hotel=$h; code=$code; month=$m; error="data 없음 resultCode=$($json.resultCode) $($json.resultMessage)" })
        continue
      }
      foreach ($day in $json.data) {
        foreach ($r in $day.usePossRoomList) {
          if ([int]$r.usePossRoomCnt -gt 0) {
            [void]$rows.Add([pscustomobject]@{
              hotel=$h; code=$code; roomCd="$($r.roomCd)"; roomNm="$($r.roomNm)"
              date=[datetime]::ParseExact("$($day.clndDt)", "yyyyMMdd", $null)
              applicants=[int]$r.useRoomCnt; rooms=[int]$r.usePossRoomCnt
            })
          }
        }
      }
    } catch {
      [void]$failed.Add([pscustomobject]@{ hotel=$h; code=$code; month=$m; error=$_.Exception.Message })
    }
  }
}

# 같은 숙소·객실을 날짜순으로 묶고, 연속된 두 날짜(같은 신청자 수)를 2박 1건으로 처리
$stays = New-Object System.Collections.ArrayList
$flags = New-Object System.Collections.ArrayList
$groups = $rows | Group-Object { "$($_.hotel)|$($_.roomCd)|$($_.roomNm)" }
foreach ($g in $groups) {
  $list = @($g.Group | Sort-Object date)
  $i = 0
  while ($i -lt $list.Count) {
    $a = $list[$i]
    $b = if ($i + 1 -lt $list.Count) { $list[$i + 1] } else { $null }
    if ($b -and (($b.date - $a.date).Days -eq 1) -and $a.applicants -eq $b.applicants -and $a.rooms -eq $b.rooms) {
      [void]$stays.Add([pscustomobject]@{
        hotel=$a.hotel; code=$a.code; roomNm=$a.roomNm; roomCd=$a.roomCd
        checkIn=$a.date.ToString("yyyy-MM-dd"); checkOut=$b.date.ToString("yyyy-MM-dd")
        applicants=$a.applicants; rooms=$a.rooms
      })
      $i += 2
    } else {
      [void]$flags.Add([pscustomobject]@{
        hotel=$a.hotel; roomNm=$a.roomNm; date=$a.date.ToString("yyyy-MM-dd")
        applicants=$a.applicants; rooms=$a.rooms; reason="짝이 맞는 연속일이 없음"
      })
      $i += 1
    }
  }
}

$out = [pscustomobject]@{
  fetchedAt = $fetchedAt
  months = @($Months)
  hotelCount = $hotels.Count
  okHotels = @($hotels.Keys | Where-Object { $h = $_; -not ($failed | Where-Object { $_.hotel -eq $h }) }).Count
  failed = @($failed)
  stays = @($stays | Sort-Object hotel, roomNm, checkIn)
  flagged = @($flags)
}
$text = $out | ConvertTo-Json -Depth 6 -Compress
[IO.File]::WriteAllText($OutPath, $text, (New-Object Text.UTF8Encoding $false))

"저장: $OutPath"
"조회 시각: $fetchedAt"
"숙소 $($out.okHotels)/$($out.hotelCount) 성공, 실패 $($failed.Count)건"
"2박 일정 $($stays.Count)건, 확인 필요 $($flags.Count)건"
if ($failed.Count -ge ($hotels.Count * @($Months).Count)) { Write-Error "모든 조회가 실패했습니다."; exit 1 }
