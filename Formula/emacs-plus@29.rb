require_relative "../Library/EmacsBase"

class EmacsPlusAT29 < EmacsBase
  init 29
  version "29.0.50"
  env :std

  #
  # Options
  #

  # Opt-out
  option "without-cocoa", "Build a non-Cocoa version of Emacs"

  # Opt-in
  option "with-ctags", "Don't remove the ctags executable that Emacs provides"
  option "with-x11", "Experimental: build with x11 support"
  option "with-debug", "Build with debug symbols and debugger friendly optimizations"
  option "with-xwidgets", "Experimental: build with xwidgets support"
  option "with-no-frame-refocus", "Disables frame re-focus (ie. closing one frame does not refocus another one)"
  option "with-native-comp", "Build with native compilation"

  #
  # Dependencies
  #

  depends_on "make" => :build
  depends_on "autoconf" => :build
  depends_on "gnu-sed" => :build
  depends_on "gnu-tar" => :build
  depends_on "awk" => :build
  depends_on "coreutils" => :build
  depends_on "pkg-config" => :build
  depends_on "texinfo" => :build
  depends_on "gnutls"
  depends_on "librsvg"
  depends_on "little-cms2"
  depends_on "jansson"
  depends_on "imagemagick" => :optional
  depends_on "dbus" => :optional
  depends_on "mailutils" => :optional

  if build.with? "x11"
    depends_on "libxaw"
    depends_on "freetype" => :recommended
    depends_on "fontconfig" => :recommended
  end

  if build.with? "native-comp"
    depends_on "libgccjit" => :recommended
    depends_on "gcc" => :build
    depends_on "gmp" => :build
    depends_on "libjpeg" => :build
    depends_on "zlib" => :build
  end

  #
  # Incompatible options
  #

  if build.with? "xwidgets"
    unless (build.with? "cocoa") && (build.without? "x11")
      odie "--with-xwidgets is not available when building --with-x11"
    end
  end

  #
  # URL
  #

  url "https://github.com/emacs-mirror/emacs.git", :branch => "master"

  #
  # Icons
  #

  inject_icon_options

  #
  # Patches
  #

  local_patch "no-frame-refocus-cocoa", sha: "fb5777dc890aa07349f143ae65c2bcf43edad6febfd564b01a2235c5a15fcabd" if build.with? "no-frame-refocus"
  local_patch "fix-window-role", sha: "1f8423ea7e6e66c9ac6dd8e37b119972daa1264de00172a24a79a710efcb8130"
  local_patch "system-appearance", sha: "d6ee159839b38b6af539d7b9bdff231263e451c1fd42eec0d125318c9db8cd92"
  local_patch "bgex", sha: "b6b468f331a5ee83c7d34ff9b83a7689c12aa24d2bfefa92baaa21c24226a23d"

  #
  # Initialize
  #

  def initialize(name, path, spec, alias_path: nil, force_bottle: false)
    super
    expand_path
  end

  #
  # Install
  #

  def install
    expand_path

    args = %W[
      --disable-dependency-tracking
      --disable-silent-rules
      --enable-locallisppath=#{HOMEBREW_PREFIX}/share/emacs/site-lisp
      --infodir=#{info}/emacs
      --prefix=#{prefix}
    ]

    args << "--with-xml2"
    args << "--with-gnutls"

    args << "--with-native-compilation" if build.with? "native-comp"

    ENV.append "CFLAGS", "-g -Og" if build.with? "debug"

    args <<
      if build.with? "dbus"
        "--with-dbus"
      else
        "--without-dbus"
      end

    # Note that if ./configure is passed --with-imagemagick but can't find the
    # library it does not fail but imagemagick support will not be available.
    # See: https://debbugs.gnu.org/cgi/bugreport.cgi?bug=24455
    args <<
      if build.with?("imagemagick")
        "--with-imagemagick"
      else
        "--without-imagemagick"
      end

    if build.with? "imagemagick"
      imagemagick_lib_path = Formula["imagemagick"].opt_lib/"pkgconfig"
      ohai "ImageMagick PKG_CONFIG_PATH: ", imagemagick_lib_path
      ENV.prepend_path "PKG_CONFIG_PATH", imagemagick_lib_path
    end

    args << "--with-modules"
    args << "--with-rsvg"
    args << "--without-pop" if build.with? "mailutils"
    args << "--with-xwidgets" if build.with? "xwidgets"

    ENV.prepend_path "PATH", Formula["gnu-sed"].opt_libexec/"gnubin"
    system "./autogen.sh"

    if (build.with? "cocoa") && (build.without? "x11")
      args << "--with-ns" << "--disable-ns-self-contained"

      system "./configure", *args

      # Disable aligned_alloc on Mojave. See issue: https://github.com/daviderestivo/homebrew-emacs-head/issues/15
      if MacOS.version <= :mojave
        ohai "Force disabling of aligned_alloc on macOS <= Mojave"
        configure_h_filtered = File.read("src/config.h")
                                   .gsub("#define HAVE_ALIGNED_ALLOC 1", "#undef HAVE_ALIGNED_ALLOC")
                                   .gsub("#define HAVE_DECL_ALIGNED_ALLOC 1", "#undef HAVE_DECL_ALIGNED_ALLOC")
                                   .gsub("#define HAVE_ALLOCA 1", "#undef HAVE_ALLOCA")
                                   .gsub("#define HAVE_ALLOCA_H 1", "#undef HAVE_ALLOCA_H")
        File.open("src/config.h", "w") do |f|
          f.write(configure_h_filtered)
        end
      end

      system "gmake"
      system "gmake", "install"

      icons_dir = buildpath/"nextstep/Emacs.app/Contents/Resources"
      ICONS_CONFIG.each_key do |icon|
        next if build.without? "#{icon}-icon"

        rm "#{icons_dir}/Emacs.icns"
        resource("#{icon}-icon").stage do
          icons_dir.install Dir["*.icns*"].first => "Emacs.icns"
        end
      end

      # (prefix/"share/emacs/#{version}").install "lisp"
      prefix.install "nextstep/Emacs.app"

      # inject PATH to Info.plist
      inject_path

      # Replace the symlink with one that avoids starting Cocoa.
      (bin/"emacs").unlink # Kill the existing symlink
      (bin/"emacs").write <<~EOS
        #!/bin/bash
        exec #{prefix}/Emacs.app/Contents/MacOS/Emacs "$@"
      EOS
    else
      if build.with? "x11"
        # These libs are not specified in xft's .pc. See:
        # https://trac.macports.org/browser/trunk/dports/editors/emacs/Portfile#L74
        # https://github.com/Homebrew/homebrew/issues/8156
        ENV.append "LDFLAGS", "-lfreetype -lfontconfig"
        args << "--with-x"
        args << "--with-gif=no" << "--with-tiff=no" << "--with-jpeg=no"
      else
        args << "--without-x"
      end
      args << "--without-ns"

      system "./configure", *args

      # Disable aligned_alloc on Mojave. See issue: https://github.com/daviderestivo/homebrew-emacs-head/issues/15
      if MacOS.version <= :mojave
        ohai "Force disabling of aligned_alloc on macOS <= Mojave"
        configure_h_filtered = File.read("src/config.h")
                                   .gsub("#define HAVE_ALIGNED_ALLOC 1", "#undef HAVE_ALIGNED_ALLOC")
                                   .gsub("#define HAVE_DECL_ALIGNED_ALLOC 1", "#undef HAVE_DECL_ALIGNED_ALLOC")
                                   .gsub("#define HAVE_ALLOCA 1", "#undef HAVE_ALLOCA")
                                   .gsub("#define HAVE_ALLOCA_H 1", "#undef HAVE_ALLOCA_H")
        File.open("src/config.h", "w") do |f|
          f.write(configure_h_filtered)
        end
      end

      system "gmake"
      system "gmake", "install"
    end

    # Follow MacPorts and don't install ctags from Emacs. This allows Vim
    # and Emacs and ctags to play together without violence.
    if build.without? "ctags"
      (bin/"ctags").unlink
      (man1/"ctags.1.gz").unlink
    end
  end

  def caveats
    <<~EOS
      Emacs.app was installed to:
        #{prefix}

      To link the application to default Homebrew App location:
        ln -s #{prefix}/Emacs.app /Applications

      Your PATH value was injected into Emacs.app/Contents/Info.plist

      Report any issues to http://github.com/d12frosted/homebrew-emacs-plus
    EOS
  end

  plist_options :manual => "emacs"

  def plist
    <<~EOS
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
        <key>Label</key>
        <string>#{plist_name}</string>
        <key>ProgramArguments</key>
        <array>
          <string>#{opt_bin}/emacs</string>
          <string>--fg-daemon</string>
        </array>
        <key>RunAtLoad</key>
        <true/>
        <key>StandardOutPath</key>
        <string>/tmp/homebrew.mxcl.emacs-plus.stdout.log</string>
        <key>StandardErrorPath</key>
        <string>/tmp/homebrew.mxcl.emacs-plus.stderr.log</string>
      </dict>
      </plist>
    EOS
  end

  test do
    assert_equal "4", shell_output("#{bin}/emacs --batch --eval=\"(print (+ 2 2))\"").strip
  end
end
