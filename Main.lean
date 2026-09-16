import Hashi

def main : IO Unit :=
  let capitals : Hashi.HashMap String String :=
    {} |>.insert "France" "Paris" |>.insert "Japan" "Tokyo"
  IO.println s!"Japan: {capitals.get? "Japan"}, entries: {capitals.size}"
