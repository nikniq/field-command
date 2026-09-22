Name:           field-command
Version:        1.9.0
Release:        1%{?dist}
Summary:        Real-time strategy game: mine crystal, build an army, destroy the enemy base

License:        MIT
URL:            https://example.invalid/field-command
Source0:        %{name}-%{version}.tar.gz

BuildArch:      noarch
BuildRequires:  make
BuildRequires:  python3-devel
BuildRequires:  desktop-file-utils
BuildRequires:  libappstream-glib

Requires:       python3
Requires:       python3-pygame >= 2.1
Requires:       python3-cairo
Requires:       python3-numpy
Requires:       hicolor-icon-theme

%description
Field Command is a classic real-time strategy game. Engineers mine crystal and
construct a base, Barracks and Factories train Rangers and Siege Tanks, and a
computer opponent expands, defends and sends escalating attack waves. Features
fog of war, three difficulty levels, an objectives guide, control groups,
shift-queued orders and procedurally generated artwork and sound.

%prep
%autosetup -n %{name}-%{version}

%build
# Pure Python; nothing to compile.

%install
%make_install PREFIX=%{_prefix}
%py_byte_compile %{python3} %{buildroot}%{_datadir}/%{name}/fieldcommand

%check
desktop-file-validate %{buildroot}%{_datadir}/applications/%{name}.desktop
appstream-util validate-relax --nonet %{buildroot}%{_metainfodir}/%{name}.metainfo.xml

%files
%doc README.md
%{_bindir}/%{name}
%{_datadir}/%{name}/
%{_datadir}/applications/%{name}.desktop
%{_metainfodir}/%{name}.metainfo.xml
%{_datadir}/icons/hicolor/*/apps/%{name}.png

%changelog
* Tue Sep 22 2026 Field Command Developers <noreply@example.invalid> - 1.9.0-1
- The computer opponent watches your army and builds to counter it, keeps its Snipers at range, and raids

* Tue Sep 22 2026 Field Command Developers <noreply@example.invalid> - 1.8.1-1
- UI scale: the interface is drawn at 2x on 4K and 1.5x on 1440p screens (or as set on the title screen)
- F12 saves a screenshot and an environment note to ~/Pictures

* Tue Sep 22 2026 Field Command Developers <noreply@example.invalid> - 1.8.0-1
- The Armory (Y): buy kit for your troops with crystal, worn by every unit of that type all match
- Network protocol 8

* Tue Sep 22 2026 Field Command Developers <noreply@example.invalid> - 1.7.1-1
- Command-card titles no longer overflow their buttons; upgrades get short button labels

* Tue Sep 22 2026 Field Command Developers <noreply@example.invalid> - 1.7.0-1
- Veterancy: units earn ranks at 2, 5 and 10 kills, each adding 10% damage and health
- Watchtowers: three neutral control points per map; hold one for 8 seconds to see 700 around it
- Attackers reveal themselves for 2.5 seconds when they hit you, even from beyond your sight
- Network protocol 7

* Tue Sep 22 2026 Field Command Developers <noreply@example.invalid> - 1.6.1-1
- The command card no longer goes blank for a mixed selection of buildings
- Command-card icons sit on a dark plate for contrast; large buildings no longer pop at the screen edge

* Mon Sep 21 2026 Field Command Developers <noreply@example.invalid> - 1.6.0-1
- Building upgrades: Reinforce, Armour plating, Assembly line, Expanded storage, Twin cannon
- Network protocol 6

* Mon Sep 21 2026 Field Command Developers <noreply@example.invalid> - 1.5.0-1
- Siege Tanks can dig in: longer reach and heavier shells, immobile, with a blind spot
- Network protocol 5

* Mon Sep 21 2026 Field Command Developers <noreply@example.invalid> - 1.4.0-1
- Single-player games can be played in teams with computer allies
- "Play again" keeps the chosen map, opponents and teams

* Mon Sep 21 2026 Field Command Developers <noreply@example.invalid> - 1.3.0-1
- Engineers repair damaged buildings, paying for the health as it goes back on
- Locked build icons stay visible in greyscale instead of fading into the button
- Fix a crash selecting an Engineer that is rebuilding a bridge
- Cache bridge artwork, which was being re-rendered every frame
- Network protocol 4

* Mon Sep 21 2026 Field Command Developers <noreply@example.invalid> - 1.2.0-1
- Bridges can be destroyed and rebuilt by Engineers; a fallen span blocks the crossing
- Network protocol 3: bridge condition now travels with each snapshot

* Mon Sep 21 2026 Field Command Developers <noreply@example.invalid> - 1.1.0-1
- Add the Sniper (Barracks, needs a Factory) and the Radar Station
- Network protocol 2: 1.0.0 clients cannot join a 1.1.0 game

* Sat Sep 19 2026 Field Command Developers <noreply@example.invalid> - 1.0.0-1
- Initial Linux release
