# Log Projektu: Skrypt Bash do Divinumofficium.com

## Zapytanie użytkownika:
Utworzyć skrypt bash który:
- Przyjmuje jeden argument ze zbioru: [Prima, Tertia, Sexta, Nona, Vesperae]
- Pobiera dane ze strony https://www.divinumofficium.com/cgi-bin/horas/officium.pl
- Znajduje linki ukryte pod hover dla wybranej modlitwy (Laudes, Prima, Tertia, Sexta, Nona, Vesperae)
- Pobiera tekst od części "Incipit" aż do końca części "Conclusio"
- Wyświetla zawartość w terminalu

## Krok 1: Analiza struktury strony
Data: 2026-01-13 22:12

Pobieram główną stronę aby zrozumieć strukturę HTML i znaleźć linki do poszczególnych modlitw.

### Wyniki analizy:
- Strona używa parametru `command=pray{NazwaModlitwy}` w URL
- Przykład: `officium.pl?command=prayPrima`
- Treść modlitwy znajduje się w tabeli HTML
- Sekcja "Incipit" to początek (oznaczona znacznikiem `<FONT SIZE='+1' COLOR="red"><B><I>Incipit</I></B></FONT>`)
- Sekcja "Conclusio" to koniec (analogicznie oznaczona)
- Treść jest w formacie HTML z tagami FONT, BR, itd.

## Krok 2: Tworzenie skryptu bash
Data: 2026-01-13 22:12

Tworzę skrypt który:
1. Waliduje argument wejściowy
2. Buduje URL z odpowiednim parametrem command
3. Pobiera stronę za pomocą curl
4. Ekstrahuje treść od "Incipit" do końca "Conclusio"
5. Czyści HTML i formatuje dla terminala

### Pierwsze podejście:
- Utworzono plik `divinumofficium.sh`
- Użyto sed do ekstrakcji, ale nie działało prawidłowo

### Poprawki:
- Zmieniono na awk, który czyta od Incipit do zamknięcia </TABLE>
- Dodano filtry do usunięcia linków nawigacyjnych (Top, Next)
- Dodano dekodowanie encji HTML

## Krok 3: Testowanie skryptu
Data: 2026-01-13 22:12

### Testy przeprowadzone:
1. ✅ `./divinumofficium.sh Prima` - działa poprawnie
2. ✅ `./divinumofficium.sh Vesperae` - działa poprawnie
3. ✅ `./divinumofficium.sh Sexta` - działa poprawnie
4. ✅ Brak argumentu - wyświetla instrukcję użycia
5. ✅ Nieprawidłowy argument (Laudes) - wyświetla błąd

### Wnioski:
Skrypt działa zgodnie z wymaganiami:
- Przyjmuje argumenty: Prima, Tertia, Sexta, Nona, Vesperae
- Pobiera treść od "Incipit" do końca "Conclusio"
- Wyświetla czytelnie w terminalu (z tekstem łacińskim i angielskim)
- Waliduje dane wejściowe
- Obsługuje błędy połączenia

## Podsumowanie
Data: 2026-01-13 22:13

Utworzono działający skrypt bash `divinumofficium.sh`, który:
- Lokalizacja: `/home/adam/copilot_workspace/kasprzak_project/divinumofficium.sh`
- Rozmiar: ~1.8KB
- Uprawnienia: wykonywalne (chmod +x)
- Status: UKOŃCZONE ✅

## Krok 4: Modyfikacja obsługi argumentów
Data: 2026-01-13 22:17

### Zapytanie użytkownika:
"popraw aby argumenty pisać małymi literami"

### Zmiany wprowadzone:
- Argumenty przyjmowane są teraz małymi literami: prima, tertia, sexta, nona, vesperae
- Dodano automatyczną konwersję: pierwsza litera na wielką (bo API wymaga Prima, Tertia, etc.)
- Zaktualizowano komunikaty pomocy i błędów
- Zachowano zgodność z API (nadal wysyła "Prima", "Tertia", etc.)

### Test:
Teraz użytkownik może pisać: `./divinumofficium.sh prima` zamiast `./divinumofficium.sh Prima`

## Krok 5: Filtrowanie tylko tekstu łacińskiego
Data: 2026-01-13 22:22

### Zapytanie użytkownika:
"wynik jest po łacinie i angielsku. Ma być tylko część po łacinie"

### Analiza problemu:
Strona HTML zawiera tabelę z dwiema kolumnami:
- Pierwsza kolumna (`<TD WIDTH='50%'>`): tekst łaciński
- Druga kolumna (`<TD WIDTH='50%'>`): tekst angielski

### Zmiany wprowadzone:
- Zmodyfikowano skrypt awk aby pomijać drugą kolumnę (angielską)
- Dodano wykrywanie początku drugiej kolumny (po numerze sekcji)
- Dodano filtr usuwający pojedyncze cyfry (numery sekcji)
- Zachowano tylko tekst łaciński w wyniku

### Test:
```bash
./divinumofficium.sh prima    # Wyświetla tylko tekst łaciński
./divinumofficium.sh vesperae # Wyświetla tylko tekst łaciński
```

Wynik zawiera teraz wyłącznie modlitwy w języku łacińskim.

## Krok 6: Dodanie odstępów między sekcjami
Data: 2026-01-13 22:28

### Zapytanie użytkownika:
"może dodaj jeszcze wolną linię między częściami <td>"

### Zmiany wprowadzone:
- Dodano pustą linię po każdym `</TR>` (koniec sekcji w tabeli)
- Użyto `cat -s` aby zredukować wielokrotne puste linie do maksymalnie dwóch
- Sekcje są teraz lepiej wizualnie oddzielone

### Efekt:
Każda sekcja modlitwy (Incipit, Hymnus, Psalmi, Lectio brevis, Conclusio, etc.) jest oddzielona pustą linią, co poprawia czytelność w terminalu.

Przykład:
```
Incipit 

℣. Deus ✠ in adiutórium...

Hymnus 

Iam lucis orto sídere...

Psalmi {ex Psalterio...
```
