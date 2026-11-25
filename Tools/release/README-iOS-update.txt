PJDV M39 0.2.1 (build 7) · iPhone / iPad

这份更新需要你已在本地保留 0.2.0 build 1 的原始未签名 IPA。在装有 Python 3.9 或更新版本的电脑上解压本下载，打开终端或 PowerShell，切换到解压目录，执行下面的命令。将两个 IPA 路径替换成自己的文件位置，输出文件名必须尚未使用。

This update requires your own original, unsigned PJDV M39 0.2.0 build 1 IPA. Extract this download on a computer with Python 3.9 or later. In a terminal or PowerShell, change to the extracted directory and run the command below. Substitute your own input and output locations. The output file must be new.

python3 pjdv_ios_update.py "/path/to/build1-unsigned.ipa" PJDVM39-0.2.0b1-to-0.2.1-iOS-host-update.zip "/path/to/PJDVM39-0.2.1-iOS-unsigned.ipa"

Windows 安装 Python 时如果使用了 py 启动器，将开头的 python3 换成 py -3。保留约 600 MB 可用空间。工具在电脑上重建并校验全部 2,896 个 App 文件，成功后使用你平时的签名工具签名并安装输出 IPA。建议先备份存档并使用与原安装相同的签名身份和应用标识，以便覆盖安装。工具不会读取 iPhone 或 iPad 的个人数据。

On Windows you may use py -3 in place of python3. Allow about 600 MB of free space. The updater reconstructs and verifies all 2,896 app files locally. Sign the resulting IPA with your usual signing tool. Back up your saves and use the same signing identity and app identifier when installing over an existing copy.

SHA-256
build 1 unsigned IPA
31b99dc74980bd8288ae125bf8a09f849bf9801895a4102ff07e4487d00786e2
0.2.1 (build 7) reconstructed unsigned IPA
befcacab2d42e2aa28de711a20aaa83d8524a9b44086cb1cf6ebca6581289a2b
