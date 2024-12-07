
# Získ polygonů povodí nad vodoměrnými stanicemi v Česku ------------------

# načtení balíčků
xfun::pkg_attach2("tidyverse",
                  "sf",
                  "arcgislayers")

# budeme potřebovat dobré připojení k internetu, protože podkladové vrstvy stahujeme
# předpokládá se, že známe adresu polygonové vrstvy s rozvodnicemi
# adresu včetně čísla vrstvy najdeme mezi otevřenými prostorovými daty ĆHMÚ (https://open-data-chmi.hub.arcgis.com/)
# klidně si dovolíme načíst celou nejpodrobnější vrstvu s rozšířenými rozvodnicemi 4. řádu
# někdy je potřeba následující řádky spustit vícekrát, aby proces načítání skončil úspěchem
# nakonec ještě převádíme na přehlednější tibble simple feature
# jen pro ukázku si děláme pořádek v chybějících hodnotách v textových polích
rozv <- arc_read("https://services1.arcgis.com/ZszVN9lBVA5x4VmX/arcgis/rest/services/rozvodnice5G_4_radu_plus/FeatureServer/6") |> 
  as_tibble() |> 
  st_sf() |> 
  mutate(across(where(is.character),
                \(x) if_else(x == "", NA, x)))

# omezíme se jen na řádky, kde je stanice
# jelikož ČHMÚ pro fungující stanice používá identifikátory připomínající šestimístné číslo (s vodícími nulami), dovolíme si využít vedlejšího efektu
stanice <- rozv |> 
  filter(!is.na(as.numeric(dbcn))) |> 
  st_drop_geometry() # protože geometrii nepotřebujeme a jen by zdržovala

# tohoto pomocneho objektu využijeme k vyběru všech menších polygonů nad stanicemi
# výsledky si vytvoříme jako nový sloupec tabulky, abychom měli všechno pěkně přiřazené
stanice <- stanice |> 
  group_by(id = dbcn) |> 
  nest()

# využíváme znalosti atributové tabulky a podmínku příslušnosti povodí nad vodoměrnou stanicí
stanice <- stanice |> 
  mutate(data2 = data |>
           map(\(x) filter(rozv, chp_14_s >= x$chp_14_s_u & chp_14_s <= x$chp_14_s))
  )

# pro jednotlivé stanice provedeme sjednocení geometrie
# převedeme na sf a upravíme název geometrie
# jelikož tohle trvá docela dlouho, zkusme proces paralelizovat podle našich možností
library(furrr)
plan(multisession,
     workers = availableCores() - 1) # raději si ještě jeden zbývající procesor necháváme stranou (příliš pracovníků se může prát o RAM a zpomalovat tím výpočet)

stanice <- stanice |> 
  ungroup() |> # někdy je pro paralelní zpracování nutné tabulku zbavit grupování, jinak se spouští proces jen sekvenčně
  mutate(data2 = data2 |> 
           future_map(\(x) st_union(x) |> 
                        st_sf() |> 
                        st_set_geometry("geoms"),
                      .options = furrr_options(seed = NULL, # protože nepotřebujeme generovat pseudonáhodná čísla
                                               packages = "sf"))) # je potřeba upřesnit, jaké další balíčky poskytují funkce, které ostatní pracovníci (workers) neznají

# přecházíme zpět na sekvenční zpracování
plan(sequential)

# někdy po sjednocování zbývají ve výsledných polygonech artefakty ve formě děr
# podívejme se, zda existuje nějaká geometrie, která není validní
stanice <- stanice |> 
  select(id, data2) |> 
  unnest(data2) |> 
  st_sf()

stanice |> 
  filter(!st_is_valid(geoms))

# všechny geometrie jsou validní

# jelikož některá povodí mohou být subpovodími vetších povodí, je vhodné si vrstvu uspořádat tak, aby nejmenší povodí byla v tabulce dole
# docílíme tím i toho, že se vrstva bude lépe kreslit (s největšími povodími na prvním míste a s nejmenšími dole)
# alternativou je nechat geometrii a další atributy zahnízděné
stanice <- stanice |> 
  mutate(a = st_area(st_transform(geoms, 3035)) |> 
           units::set_units(km2) |> 
           round(2)) |> 
  arrange(desc(a)) |> 
  relocate(a, .after = id)

# posledním krokem bude odstranění povodí s nulovou plochou
# takové případy mohou odkazovat na tzv. fiktivní stanice, měření náhonů apod.
stanice <- stanice |> 
  filter(a > units::set_units(0, km2)) # musíme porovnávat se správně nastavenými jednotkami

# přitom není potřeba ukládat vrstvu do souboru, který je znám v GIS
# vhodné je i uložení do RDS souboru (geometrie a vše ostatní po načtení zůstane výhodně zachováno)
write_rds(stanice,
          "geodata/povodi_vodomernych_stanic.rds")
