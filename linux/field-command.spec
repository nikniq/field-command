Name:           field-command
Version:        1.0.0
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
* Sat Sep 19 2026 Field Command Developers <noreply@example.invalid> - 1.0.0-1
- Initial Linux release
