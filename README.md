# MountFund

En addon for WoW Forever der guilden spleiser på mount. Når en påmeldt guildie er **40+ og ikke har riding ennå**, sender alle andre påmeldte **1g** hver.

## Installering
1. Last ned repoet (**Code → Download ZIP**) eller en release.
2. Kopier mappen `MountFund` inn i `Interface\AddOns` for WoW Forever.
3. Start spillet på nytt og sjekk at MountFund er huket av i AddOn-lista.

## Slik fungerer det
- Skriv `/mf join` for å melde deg på.
  - Er du under 40, får du støtte når du når 40.
  - Er du allerede 40+ uten riding, får du støtte med en gang.
- Når noen ber om støtte, får du beskjed i chatten.
- Åpne en postkasse, så dukker det opp en knapp: **«Send 1g til …»**. Ingenting sendes automatisk, du trykker alltid selv.
- **Den med høyest level står først i køen.** Ved likt level går den som har ventet lengst først.
- Når noen lærer riding, forsvinner de fra køen hos alle.

## Regler
- Hver karakter kan få støtte **bare én gang**.
- Du betaler hver person **bare én gang**, uansett hvor mange alts du har.
- Du må være påmeldt for å få gull selv.

## Kommandoer
| Kommando | Hva den gjør |
|---|---|
| `/mf` | Status |
| `/mf join` / `/mf leave` | Meld deg på eller av |
| `/mf queue` | Se køen i rekkefølge |
| `/mf who` | Se hvem som er påmeldt (av dem som er online) |
| `/mf riding` | Sjekk om addonen finner riding på karakteren |
| `/mf skip <navn>` | Hopp over én i køen |
| `/mf clear` | Tøm køen |
| `/mf add <navn>` | Legg til noen manuelt (NB: ekte gull!) |

## Kjente begrensninger
- Andre spillere kan ikke se om du har riding. Det er mottakerens egen addon som melder det, og meldingen kan forfalskes. Det mest noen kan tjene på det er 1g fra hver giver, én gang per karakter. Bruk `/mf skip <navn>` ved juks.
- Ingen addon kan tvinge noen til å sende gull. Alt bygger på at folk trykker på knappen selv.
