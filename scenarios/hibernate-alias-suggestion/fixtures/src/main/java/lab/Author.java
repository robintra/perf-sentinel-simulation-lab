package lab;

import java.util.List;

import jakarta.persistence.Entity;
import jakarta.persistence.FetchType;
import jakarta.persistence.Id;
import jakarta.persistence.OneToMany;

@Entity
public class Author {
    @Id Integer id;
    String name;
    @OneToMany(mappedBy = "author", fetch = FetchType.LAZY)
    List<Book> books;
}
