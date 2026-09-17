import Hashi

def main : IO Unit :=
  let capitals : Hashi.HashMap String String :=
    Hashi.HashMap.empty |>.insert "France" "Paris" |>.insert "Japan" "Tokyo"
  IO.println s!"Japan: {capitals.get? "Japan"}, entries: {capitals.size}"
