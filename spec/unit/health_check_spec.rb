require "spec_helper"
require "pedump"

module Omnibus
  describe HealthCheck do
    let(:project) do
      double(Project,
        name: "chefdk",
        install_dir: "/opt/chefdk",
        library: double(Library,
          components: []))
    end

    def mkdump(base, size, x64 = false)
      dump = double(PEdump)
      pe = double(PEdump::PE,
        x64?: x64,
        ioh: double(x64 ? PEdump::IMAGE_OPTIONAL_HEADER64 : PEdump::IMAGE_OPTIONAL_HEADER32,
          ImageBase: base,
          SizeOfImage: size))
      expect(dump).to receive(:pe).and_return(pe)
      dump
    end

    subject { described_class.new(project) }

    context "on windows" do
      before do
        stub_ohai(platform: "windows", version: "2012R2")
      end

      it "will perform dll base relocation checks" do
        stub_ohai(platform: "windows", version: "2012R2")
        expect(subject.relocation_checkable?).to be true
      end

      context "when performing dll base relocation checks" do
        let(:pmdumps) do
          {
            "a" => mkdump(0x10000000, 0x00001000),
            "b/b" => mkdump(0x20000000, 0x00002000),
            "c/c/c" => mkdump(0x30000000, 0x00004000),
          }
        end

        let(:search_dir) { "#{project.install_dir}/embedded/bin" }

        before do
          r = allow(Dir).to receive(:glob).with("#{search_dir}/*.dll")
          pmdumps.each do |file, dump|
            path = File.join(search_dir, file)
            r.and_yield(path)
            expect(File).to receive(:open).with(path, "rb").and_yield(double(File))
            expect(PEdump).to receive(:new).with(path).and_return(dump)
          end
        end

        context "when given non-overlapping dlls" do
          it "should always return true" do
            expect(subject.run!).to eq(true)
          end

          it "should not identify conflicts" do
            expect(subject.relocation_check).to eq({})
          end
        end

        context "when presented with overlapping dlls" do
          let(:pmdumps) do
            {
              "a" => mkdump(0x10000000, 0x00001000),
              "b/b" => mkdump(0x10000500, 0x00002000),
              "c/c/c" => mkdump(0x30000000, 0x00004000),
            }
          end

          it "should always return true" do
            expect(subject.run!).to eq(true)
          end

          it "should identify two conflicts" do
            expect(subject.relocation_check).to eq({
              "a" => {
                base: 0x10000000,
                size: 0x00001000,
                conflicts: [ "b" ],
              },
              "b" => {
                base: 0x10000500,
                size: 0x00002000,
                conflicts: [ "a" ],
              },
            })
          end
        end
      end
    end

    context "on linux" do
      before { stub_ohai(platform: "ubuntu", version: "16.04") }

      # file_list just needs to have one file which is inside of the install_dir
      let(:file_list) do
        double("Mixlib::Shellout",
          error!: false,
          stdout: <<~EOH
            /opt/chefdk/shouldnt/matter
          EOH
        )
      end

      let(:empty_list) do
        double("Mixlib::Shellout",
          error!: false,
          stdout: <<~EOH
          EOH
        )
      end

      let(:failed_list) do
        failed_list = double("Mixlib::Shellout",
          stdout: <<~EOH
            /opt/chefdk/shouldnt/matter
          EOH
        )
        allow(failed_list).to receive(:error!).and_raise("Mixlib::Shellout::ShellCommandFailed")
        failed_list
      end

      let(:bad_list) do
        double("Mixlib::Shellout",
          error!: false,
          stdout: <<~EOH
            /somewhere/other/than/install/dir
          EOH
        )
      end

      let(:bad_healthcheck) do
        double("Mixlib::Shellout",
          error!: false,
          stdout: <<~EOH
            /bin/ls:
              linux-vdso.so.1 =>  (0x00007fff583ff000)
              libselinux.so.1 => /lib/x86_64-linux-gnu/libselinux.so.1 (0x00007fad8592a000)
              librt.so.1 => /lib/x86_64-linux-gnu/librt.so.1 (0x00007fad85722000)
              libacl.so.1 => /lib/x86_64-linux-gnu/libacl.so.1 (0x00007fad85518000)
              libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007fad8518d000)
              libdl.so.2 => /lib/x86_64-linux-gnu/libdl.so.2 (0x00007fad84f89000)
              /lib64/ld-linux-x86-64.so.2 (0x00007fad85b51000)
              libpthread.so.0 => /lib/x86_64-linux-gnu/libpthread.so.0 (0x00007fad84d6c000)
              libattr.so.1 => /lib/x86_64-linux-gnu/libattr.so.1 (0x00007fad84b67000)
            /bin/cat:
              linux-vdso.so.1 =>  (0x00007fffa4dcf000)
              libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007f4a858cd000)
              /lib64/ld-linux-x86-64.so.2 (0x00007f4a85c5f000)
          EOH
        )
      end

      let(:good_healthcheck) do
        double("Mixlib::Shellout",
          error!: false,
          stdout: <<~EOH
            /bin/echo:
              linux-vdso.so.1 =>  (0x00007fff8a6ee000)
              libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007f70f58c0000)
              /lib64/ld-linux-x86-64.so.2 (0x00007f70f5c52000)
            /bin/cat:
              linux-vdso.so.1 =>  (0x00007fff095b3000)
              libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6 (0x00007fe868ec0000)
              /lib64/ld-linux-x86-64.so.2 (0x00007fe869252000)
          EOH
        )
      end

      it "raises an exception when there are external dependencies" do
        allow(subject).to receive(:shellout)
          .with("find /opt/chefdk/ -type f | xargs file | grep \"ELF\" | awk -F: '{print $1}' | sed -e 's/:$//'")
          .and_return(file_list)

        allow(subject).to receive(:shellout)
          .with("xargs ldd", { input: "/opt/chefdk/shouldnt/matter\n" })
          .and_return(bad_healthcheck)

        expect { subject.run! }.to raise_error(HealthCheckFailed)
      end

      it "does not raise an exception when the healthcheck passes" do
        allow(subject).to receive(:shellout)
          .with("find /opt/chefdk/ -type f | xargs file | grep \"ELF\" | awk -F: '{print $1}' | sed -e 's/:$//'")
          .and_return(file_list)

        allow(subject).to receive(:shellout)
          .with("xargs ldd", { input: "/opt/chefdk/shouldnt/matter\n" })
          .and_return(good_healthcheck)

        expect { subject.run! }.to_not raise_error
      end

      it "will not perform dll base relocation checks" do
        expect(subject.relocation_checkable?).to be false
      end

      it "raises an exception if there's nothing in the file list" do
        allow(subject).to receive(:shellout)
          .with("find /opt/chefdk/ -type f | xargs file | grep \"ELF\" | awk -F: '{print $1}' | sed -e 's/:$//'")
          .and_return(empty_list)

        expect { subject.run! }.to raise_error(RuntimeError, "Internal Error: Health Check found no lines")
      end

      it "raises an exception if the file list command raises" do
        allow(subject).to receive(:shellout)
          .with("find /opt/chefdk/ -type f | xargs file | grep \"ELF\" | awk -F: '{print $1}' | sed -e 's/:$//'")
          .and_return(failed_list)

        expect { subject.run! }.to raise_error(RuntimeError, "Mixlib::Shellout::ShellCommandFailed")
      end

      it "raises an exception if the file list command has no entries in the install_dir" do
        allow(subject).to receive(:shellout)
          .with("find /opt/chefdk/ -type f | xargs file | grep \"ELF\" | awk -F: '{print $1}' | sed -e 's/:$//'")
          .and_return(bad_list)

        expect { subject.run! }.to raise_error(RuntimeError, "Internal Error: Health Check lines not matching the install_dir")
      end
    end
  end
end
