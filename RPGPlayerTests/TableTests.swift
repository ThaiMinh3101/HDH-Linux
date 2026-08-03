import XCTest
@testable import RPGPlayer

/// Unit test cho M6.3 — RGSS built-in class Table (RGSSBuiltins.rb).
///
/// Xác minh:
///   1. Table 1D/2D/3D access ([] / []=) đúng index.
///   2. Table Marshal round-trip (dump → load) giữ nguyên dữ liệu.
///   3. Table khởi tạo với dim/xsize/ysize/zsize đúng.
///
/// CLEAN-ROOM: test dùng chính cơ chế của dự án (RubyBridge + RGSSBuiltins.rb)
/// — không tham chiếu engine mã nguồn mở nào.
final class TableTests: XCTestCase {

    /// Tạo RubyBridge mới (mỗi test cần VM riêng).
    private func makeBridge() -> RubyBridge {
        RubyBridge()
    }

    // MARK: - 1. Table 1D/2D/3D access

    /// Table 1D: table[x] / table[x] = v.
    func testTable1DAccess() {
        let bridge = makeBridge()
        let script = """
        t = Table.new(5)
        raise "dim sai" unless t.dim == 1
        raise "xsize sai" unless t.xsize == 5
        raise "ysize sai" unless t.ysize == 1
        raise "zsize sai" unless t.zsize == 1

        # Mặc định 0
        raise "mặc định sai" unless t[0] == 0
        raise "mặc định sai" unless t[4] == 0

        # Set/get
        t[0] = 10
        t[4] = 20
        raise "set/get sai" unless t[0] == 10
        raise "set/get sai" unless t[4] == 20

        puts "TABLE_1D_OK"
        """

        let (rc, err) = bridge.runTestScript(script)
        XCTAssertEqual(rc, 0, "Table 1D thất bại: \(err)")
    }

    /// Table 2D: table[x, y] / table[x, y] = v.
    func testTable2DAccess() {
        let bridge = makeBridge()
        let script = """
        t = Table.new(3, 4)
        raise "dim sai" unless t.dim == 2
        raise "xsize sai" unless t.xsize == 3
        raise "ysize sai" unless t.ysize == 4

        t[1, 2] = 42
        raise "set/get sai" unless t[1, 2] == 42
        raise "index khác sai" unless t[0, 0] == 0

        puts "TABLE_2D_OK"
        """

        let (rc, err) = bridge.runTestScript(script)
        XCTAssertEqual(rc, 0, "Table 2D thất bại: \(err)")
    }

    /// Table 3D: table[x, y, z] / table[x, y, z] = v.
    func testTable3DAccess() {
        let bridge = makeBridge()
        let script = """
        t = Table.new(2, 3, 4)
        raise "dim sai" unless t.dim == 3
        raise "xsize sai" unless t.xsize == 2
        raise "ysize sai" unless t.ysize == 3
        raise "zsize sai" unless t.zsize == 4

        t[1, 2, 3] = 99
        raise "set/get sai" unless t[1, 2, 3] == 99
        raise "index khác sai" unless t[0, 0, 0] == 0

        puts "TABLE_3D_OK"
        """

        let (rc, err) = bridge.runTestScript(script)
        XCTAssertEqual(rc, 0, "Table 3D thất bại: \(err)")
    }

    // MARK: - 2. Table Marshal round-trip

    /// Table dump → load giữ nguyên dữ liệu (dùng Marshal module M3).
    func testTableMarshalRoundTrip() {
        let bridge = makeBridge()
        let script = """
        t = Table.new(3, 3)
        t[0, 0] = 1
        t[1, 1] = 2
        t[2, 2] = 3

        data = Marshal.dump(t)
        t2 = Marshal.load(data)

        raise "class sai" unless t2.is_a?(Table)
        raise "dim sai" unless t2.dim == 2
        raise "xsize sai" unless t2.xsize == 3
        raise "ysize sai" unless t2.ysize == 3
        raise "data sai" unless t2[0, 0] == 1
        raise "data sai" unless t2[1, 1] == 2
        raise "data sai" unless t2[2, 2] == 3

        puts "TABLE_MARSHAL_OK"
        """

        let (rc, err) = bridge.runTestScript(script)
        XCTAssertEqual(rc, 0, "Table Marshal round-trip thất bại: \(err)")
    }

    // MARK: - 3. Table resize

    /// Table.resize giữ dữ liệu cũ trong phạm vi mới.
    func testTableResize() {
        let bridge = makeBridge()
        let script = """
        t = Table.new(3, 3)
        t[0, 0] = 1
        t[2, 2] = 2

        t.resize(5, 5)
        raise "xsize sai" unless t.xsize == 5
        raise "ysize sai" unless t.ysize == 5
        raise "data cũ sai" unless t[0, 0] == 1
        raise "data cũ sai" unless t[2, 2] == 2
        raise "data mới mặc định sai" unless t[4, 4] == 0

        puts "TABLE_RESIZE_OK"
        """

        let (rc, err) = bridge.runTestScript(script)
        XCTAssertEqual(rc, 0, "Table resize thất bại: \(err)")
    }
}